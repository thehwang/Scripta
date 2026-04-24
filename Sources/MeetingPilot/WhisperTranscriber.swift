import AVFoundation
import Foundation
import MeetingPilotCore
import WhisperKit

enum TranscriptionChannel {
    case mic
    case system
}

final class WhisperTranscriber {
    var onTranscription: ((String, TranscriptionChannel) -> Void)?

    private var whisperKit: WhisperKit?
    private let processingQueue = DispatchQueue(label: "meetingpilot.whisper-processing")

    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []
    private let bufferLock = NSLock()

    private var micTimer: DispatchSourceTimer?
    private var systemTimer: DispatchSourceTimer?
    private var isRunning = false

    // Track whether each channel is currently being transcribed
    // to avoid overlapping inference calls.
    private var micBusy = false
    private var systemBusy = false

    private let sampleRate: Double = 16_000

    // Shorter chunks = faster visual feedback.
    // Whisper works well on 2-3s segments for real-time use.
    private let chunkIntervalSeconds: Double = 2.0
    private let maxChunkSeconds: Double = 10.0
    private let minChunkSeconds: Double = 0.4

    // VAD parameters for speech-end detection
    private let vadSilenceThreshold: Float = 0.008
    private let vadSilenceSeconds: Double = 0.6
    private var micSilenceFrames: Int = 0
    private var systemSilenceFrames: Int = 0
    private var micHadSpeech = false
    private var systemHadSpeech = false

    // MARK: - Lifecycle

    func load(modelPath: String) async throws {
        let config = WhisperKitConfig(
            modelFolder: modelPath,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true
        )
        whisperKit = try await WhisperKit(config)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startChunkTimer(for: .mic)
        startChunkTimer(for: .system)
    }

    func stop() {
        isRunning = false
        micTimer?.cancel()
        systemTimer?.cancel()
        micTimer = nil
        systemTimer = nil

        processingQueue.async { [weak self] in
            self?.flushChannel(.mic)
            self?.flushChannel(.system)
        }
    }

    // MARK: - Audio Input

    func appendAudio(_ buffer: AVAudioPCMBuffer, channel: TranscriptionChannel) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

        bufferLock.lock()
        switch channel {
        case .mic: micBuffer.append(contentsOf: samples)
        case .system: systemBuffer.append(contentsOf: samples)
        }
        bufferLock.unlock()

        // VAD: detect speech→silence transitions for faster triggering
        trackVAD(samples: samples, channel: channel)
    }

    func appendAudioSamples(_ samples: [Float], channel: TranscriptionChannel) {
        bufferLock.lock()
        switch channel {
        case .mic: micBuffer.append(contentsOf: samples)
        case .system: systemBuffer.append(contentsOf: samples)
        }
        bufferLock.unlock()

        trackVAD(samples: samples, channel: channel)
    }

    // MARK: - VAD Tracking

    private func trackVAD(samples: [Float], channel: TranscriptionChannel) {
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / max(Float(samples.count), 1))
        let isSilent = rms < vadSilenceThreshold
        let silenceThresholdFrames = Int(sampleRate * vadSilenceSeconds)

        switch channel {
        case .mic:
            if isSilent {
                micSilenceFrames += samples.count
                if micHadSpeech && micSilenceFrames >= silenceThresholdFrames {
                    micHadSpeech = false
                    micSilenceFrames = 0
                    processingQueue.async { [weak self] in self?.processChunk(channel: .mic) }
                }
            } else {
                micSilenceFrames = 0
                micHadSpeech = true
            }
        case .system:
            if isSilent {
                systemSilenceFrames += samples.count
                if systemHadSpeech && systemSilenceFrames >= silenceThresholdFrames {
                    systemHadSpeech = false
                    systemSilenceFrames = 0
                    processingQueue.async { [weak self] in self?.processChunk(channel: .system) }
                }
            } else {
                systemSilenceFrames = 0
                systemHadSpeech = true
            }
        }
    }

    // MARK: - Chunk Processing

    private func startChunkTimer(for channel: TranscriptionChannel) {
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + chunkIntervalSeconds, repeating: chunkIntervalSeconds)
        timer.setEventHandler { [weak self] in
            self?.processChunk(channel: channel)
        }
        timer.resume()

        switch channel {
        case .mic: micTimer = timer
        case .system: systemTimer = timer
        }
    }

    private func processChunk(channel: TranscriptionChannel) {
        // Skip if already transcribing this channel
        switch channel {
        case .mic:
            guard !micBusy else { return }
        case .system:
            guard !systemBusy else { return }
        }

        let chunk = extractChunk(channel: channel)
        guard !chunk.isEmpty else { return }

        let minSamples = Int(sampleRate * minChunkSeconds)
        guard chunk.count >= minSamples else {
            // Put samples back
            bufferLock.lock()
            switch channel {
            case .mic: micBuffer.insert(contentsOf: chunk, at: 0)
            case .system: systemBuffer.insert(contentsOf: chunk, at: 0)
            }
            bufferLock.unlock()
            return
        }

        let rms = sqrt(chunk.map { $0 * $0 }.reduce(0, +) / Float(chunk.count))
        guard rms > vadSilenceThreshold else { return }

        switch channel {
        case .mic: micBusy = true
        case .system: systemBusy = true
        }

        transcribe(chunk, channel: channel)
    }

    private func flushChannel(_ channel: TranscriptionChannel) {
        let chunk = extractChunk(channel: channel)
        guard !chunk.isEmpty else { return }
        let minSamples = Int(sampleRate * minChunkSeconds)
        guard chunk.count >= minSamples else { return }
        transcribe(chunk, channel: channel)
    }

    private func extractChunk(channel: TranscriptionChannel) -> [Float] {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        let maxSamples = Int(sampleRate * maxChunkSeconds)
        switch channel {
        case .mic:
            let chunk: [Float]
            if micBuffer.count > maxSamples {
                chunk = Array(micBuffer.prefix(maxSamples))
                micBuffer.removeFirst(maxSamples)
            } else {
                chunk = micBuffer
                micBuffer.removeAll(keepingCapacity: true)
            }
            return chunk
        case .system:
            let chunk: [Float]
            if systemBuffer.count > maxSamples {
                chunk = Array(systemBuffer.prefix(maxSamples))
                systemBuffer.removeFirst(maxSamples)
            } else {
                chunk = systemBuffer
                systemBuffer.removeAll(keepingCapacity: true)
            }
            return chunk
        }
    }

    private func transcribe(_ audioSamples: [Float], channel: TranscriptionChannel) {
        guard let whisperKit else { return }

        Task {
            defer {
                switch channel {
                case .mic: self.micBusy = false
                case .system: self.systemBusy = false
                }
            }
            do {
                let result = try await whisperKit.transcribe(audioArray: audioSamples)
                let text = result.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text != "[BLANK_AUDIO]", text != "(blank audio)" else { return }
                await MainActor.run {
                    self.onTranscription?(text, channel)
                }
            } catch {
                mplog("WhisperTranscriber error [\(channel)]: \(error.localizedDescription)")
            }
        }
    }
}
