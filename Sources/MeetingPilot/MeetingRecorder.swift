import AVFoundation
import CoreMedia
import Foundation
import MeetingPilotCore
import Speech

final class MeetingRecorder: NSObject, ObservableObject {
    enum State: String {
        case idle = "Idle"
        case recording = "Recording"
        case transcribing = "Transcribing"
        case diarizing = "Analyzing Speakers"
        case completed = "Completed"
        case failed = "Failed"
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var statusMessage: String = "Ready to start meeting capture."
    @Published private(set) var entries: [TranscriptEntry] = []
    @Published private(set) var finalScript: String = ""
    @Published private(set) var exportedFilePath: String = ""
    @Published private(set) var lastError: String = ""

    var isRecording: Bool { state == .recording }

    var liveScript: String {
        entries.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
    }

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let systemAudioCapture = SystemAudioCapture()
    private let systemAppendQueue = DispatchQueue(label: "meetingpilot.system-audio-append")
    private let recognitionFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var micRequest: SFSpeechAudioBufferRecognitionRequest?
    private var micTask: SFSpeechRecognitionTask?
    private var systemRequest: SFSpeechAudioBufferRecognitionRequest?
    private var systemTask: SFSpeechRecognitionTask?
    private var systemAudioConverter: AVAudioConverter?

    private var recordingStartedAt: Date?
    private var recordingEndedAt: Date?

    /// Raw Float32 mono 16 kHz samples from the system audio channel,
    /// accumulated for post-recording speaker diarization.
    private var systemAudioBuffer: [Float] = []
    private let systemBufferQueue = DispatchQueue(label: "meetingpilot.system-audio-buffer")

    // Per-speaker accumulation state.
    private var committedMicLen: Int = 0
    private var committedSystemLen: Int = 0
    private var activeMicIdx: Int?
    private var activeSystemIdx: Int?
    private var activeMicStart: Date?
    private var activeSystemStart: Date?

    // Track whether each task ever produced a result (to avoid restarting
    // tasks that failed before receiving any audio).
    private var micTaskProducedResult = false
    private var systemTaskProducedResult = false

    private static let commitTimeSec: TimeInterval = 10
    private static let commitChars = 200
    private static let commitCharsWithPunct = 50

    // MARK: Public API

    func startRecording() async {
        guard state != .recording else { return }

        clearPreviousResult()

        do {
            mplog("startRecording: requesting permissions...")
            try await ensurePermissions()
            mplog("startRecording: permissions OK, starting pipeline...")
            try await beginDualRecognitionPipeline()
            recordingStartedAt = Date()
            recordingEndedAt = nil
            state = .recording
            statusMessage = "Recording — dual channel (You + Remote)..."
            mplog("startRecording: pipeline started, state = recording")
        } catch let error as SystemAudioCapture.CaptureError where error == .permissionDenied {
            state = .idle
            statusMessage = "Screen Recording permission required. Grant it in System Settings, then click Start again."
            lastError = error.localizedDescription
            mplog("startRecording: screen recording permission denied")
        } catch {
            mplog("startRecording FAILED: \(error.localizedDescription)")
            setFailure(error.localizedDescription)
        }
    }

    func stopRecording() {
        guard state == .recording else { return }
        state = .transcribing
        statusMessage = "Finishing transcription..."
        mplog("stopRecording: transitioning to transcribing")
        recordingEndedAt = Date()

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        micRequest?.endAudio()
        systemRequest?.endAudio()
        Task { await systemAudioCapture.stop() }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self.state == .transcribing {
                mplog("stopRecording: timeout — forcing export")
                self.finishAndExport()
            }
        }
    }

    // MARK: Setup

    private func clearPreviousResult() {
        state = .idle
        statusMessage = "Ready to start meeting capture."
        entries = []
        finalScript = ""
        exportedFilePath = ""
        lastError = ""
        committedMicLen = 0; committedSystemLen = 0
        activeMicIdx = nil; activeSystemIdx = nil
        activeMicStart = nil; activeSystemStart = nil
        micTaskProducedResult = false; systemTaskProducedResult = false
        micTask?.cancel(); micTask = nil; micRequest = nil
        systemTask?.cancel(); systemTask = nil; systemRequest = nil
        systemAudioConverter = nil
        systemAudioBuffer = []
        Task { await systemAudioCapture.stop() }
    }

    private func ensurePermissions() async throws {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw NSError(domain: "MeetingPilot", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission denied."])
        }

        let micGranted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard micGranted else {
            throw NSError(domain: "MeetingPilot", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied."])
        }
    }

    // MARK: Dual-channel pipeline

    private func beginDualRecognitionPipeline() async throws {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw NSError(domain: "MeetingPilot", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is not available."])
        }

        // --- Channel 1: Microphone (You) ---
        let micReq = SFSpeechAudioBufferRecognitionRequest()
        micReq.shouldReportPartialResults = true
        micReq.requiresOnDeviceRecognition = true
        micRequest = micReq

        let inputNode = audioEngine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            self?.micRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        micTask = speechRecognizer.recognitionTask(with: micReq) { [weak self] result, error in
            self?.handleRecognitionResult(result: result, error: error, speaker: "You")
        }

        // --- Channel 2: System Audio (Remote) ---
        let sysReq = SFSpeechAudioBufferRecognitionRequest()
        sysReq.shouldReportPartialResults = true
        sysReq.requiresOnDeviceRecognition = true
        systemRequest = sysReq

        systemAudioCapture.onAudioSampleBuffer = { [weak self] sampleBuffer in
            self?.appendSystemAudioToRequest(sampleBuffer)
        }
        systemAudioCapture.onError = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.state == .recording || self.state == .transcribing else { return }
                self.setFailure("System audio capture failed: \(error.localizedDescription)")
            }
        }
        try await systemAudioCapture.start()
        mplog("system audio capture started")

        systemTask = speechRecognizer.recognitionTask(with: sysReq) { [weak self] result, error in
            self?.handleRecognitionResult(result: result, error: error, speaker: "Remote")
        }
        mplog("both recognition tasks created")
    }

    // MARK: Recognition result handling

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?, speaker: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isMic = speaker == "You"

            if let result {
                // Mark that this task produced at least one result.
                if isMic { self.micTaskProducedResult = true }
                else { self.systemTaskProducedResult = true }

                let text = result.bestTranscription.formattedString
                mplog("[\(speaker)] result (isFinal=\(result.isFinal)) len=\(text.count): \(String(text.prefix(80)))")
                self.processPartialResult(result, speaker: speaker)

                if result.isFinal {
                    self.handleTaskFinished(speaker: speaker, willRestart: true)
                }
            }

            if let error {
                mplog("[\(speaker)] error: \(error.localizedDescription)")
                let produced = isMic ? self.micTaskProducedResult : self.systemTaskProducedResult

                if self.state == .recording && produced {
                    // Task ran successfully then expired (e.g. 60s limit) — restart.
                    mplog("[\(speaker)] task had results → restart")
                    self.handleTaskFinished(speaker: speaker, willRestart: true)
                } else if self.state == .recording {
                    // Task failed immediately without producing results (e.g. "No speech
                    // detected" race). Do NOT restart — just leave the channel idle.
                    mplog("[\(speaker)] task had NO results → skip restart")
                } else if self.state == .transcribing {
                    self.handleTaskFinished(speaker: speaker, willRestart: false)
                }
            }
        }
    }

    /// Common cleanup when a recognition task ends.
    private func handleTaskFinished(speaker: String, willRestart: Bool) {
        let isMic = speaker == "You"
        freezeActiveEntry(speaker: speaker)

        if willRestart && state == .recording {
            restartRecognitionTask(speaker: speaker)
        } else {
            if isMic { micTask = nil } else { systemTask = nil }
            if micTask == nil && systemTask == nil && state == .transcribing {
                finishAndExport()
            }
        }
    }

    private func processPartialResult(_ result: SFSpeechRecognitionResult, speaker: String) {
        let fullText = result.bestTranscription.formattedString
        let isMic = speaker == "You"
        var comLen = isMic ? committedMicLen : committedSystemLen

        // If the recognizer revised/shortened below our committed mark, reset.
        if fullText.count < comLen {
            comLen = 0
            setCommitted(0, isMic: isMic)
        }

        guard comLen < fullText.count else { return }

        let start = fullText.index(fullText.startIndex, offsetBy: comLen)
        let uncommitted = String(fullText[start...]).trimmingCharacters(in: .whitespaces)
        guard !uncommitted.isEmpty else { return }

        let now = Date()
        let activeIdx = isMic ? activeMicIdx : activeSystemIdx
        let activeStart = isMic ? activeMicStart : activeSystemStart

        var shouldCommit = false
        if let t0 = activeStart {
            let elapsed = now.timeIntervalSince(t0)
            let hasPunct = uncommitted.unicodeScalars.contains { c in
                c == "." || c == "!" || c == "?"
            }
            if elapsed > Self.commitTimeSec && uncommitted.count > 30 {
                shouldCommit = true
            } else if hasPunct && uncommitted.count > Self.commitCharsWithPunct {
                shouldCommit = true
            } else if uncommitted.count > Self.commitChars {
                shouldCommit = true
            }
        }

        if shouldCommit {
            if let idx = activeIdx, idx < entries.count {
                entries[idx].text = uncommitted
            } else {
                entries.append(TranscriptEntry(speaker: speaker, text: uncommitted))
            }
            setCommitted(fullText.count, isMic: isMic)
            clearActive(isMic: isMic)
        } else {
            if let idx = activeIdx, idx < entries.count {
                entries[idx].text = uncommitted
            } else {
                let newIdx = entries.count
                entries.append(TranscriptEntry(speaker: speaker, text: uncommitted))
                setActive(index: newIdx, start: now, isMic: isMic)
            }
        }
    }

    /// Freeze the current active entry (keep its text, stop updating it).
    private func freezeActiveEntry(speaker: String) {
        let isMic = speaker == "You"
        clearActive(isMic: isMic)
        setCommitted(0, isMic: isMic)
    }

    /// Start a fresh recognition task so recording continues past the ~60 s limit.
    private func restartRecognitionTask(speaker: String) {
        guard let speechRecognizer, speechRecognizer.isAvailable,
              state == .recording else {
            mplog("restartTask [\(speaker)] skipped")
            return
        }
        mplog("restartTask [\(speaker)] creating new task")

        let newReq = SFSpeechAudioBufferRecognitionRequest()
        newReq.shouldReportPartialResults = true
        newReq.requiresOnDeviceRecognition = true

        let isMic = speaker == "You"
        setCommitted(0, isMic: isMic)

        if isMic {
            micTaskProducedResult = false
            micRequest = newReq
            micTask = speechRecognizer.recognitionTask(with: newReq) { [weak self] result, error in
                self?.handleRecognitionResult(result: result, error: error, speaker: "You")
            }
        } else {
            systemTaskProducedResult = false
            systemRequest = newReq
            systemTask = speechRecognizer.recognitionTask(with: newReq) { [weak self] result, error in
                self?.handleRecognitionResult(result: result, error: error, speaker: "Remote")
            }
        }
    }

    // MARK: Per-speaker state helpers

    private func setCommitted(_ n: Int, isMic: Bool) {
        if isMic { committedMicLen = n } else { committedSystemLen = n }
    }

    private func clearActive(isMic: Bool) {
        if isMic { activeMicIdx = nil; activeMicStart = nil }
        else { activeSystemIdx = nil; activeSystemStart = nil }
    }

    private func setActive(index: Int, start: Date, isMic: Bool) {
        if isMic { activeMicIdx = index; activeMicStart = start }
        else { activeSystemIdx = index; activeSystemStart = start }
    }

    // MARK: System audio -> recognition request

    private func appendSystemAudioToRequest(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }

        let buffer: AVAudioPCMBuffer
        if pcm.format.sampleRate == recognitionFormat.sampleRate &&
            pcm.format.channelCount == recognitionFormat.channelCount &&
            pcm.format.commonFormat == recognitionFormat.commonFormat {
            buffer = pcm
        } else {
            guard let converted = convertToRecognitionFormat(pcm) else { return }
            buffer = converted
        }

        // Accumulate raw PCM for post-recording diarization.
        if let channelData = buffer.floatChannelData {
            let frameCount = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            systemBufferQueue.async { [weak self] in
                self?.systemAudioBuffer.append(contentsOf: samples)
            }
        }

        systemAppendQueue.async { [weak self] in
            self?.systemRequest?.append(buffer)
        }
    }

    private func convertToRecognitionFormat(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if systemAudioConverter == nil {
            systemAudioConverter = AVAudioConverter(from: input.format, to: recognitionFormat)
        }
        guard let converter = systemAudioConverter else { return nil }

        let frameCount = AVAudioFrameCount(
            Double(input.frameLength) * recognitionFormat.sampleRate / input.format.sampleRate + 32
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: recognitionFormat, frameCapacity: max(frameCount, 32)) else {
            return nil
        }

        var provided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error else { return nil }
        return output
    }

    // MARK: Finish & export

    private func finishAndExport() {
        guard state != .completed && state != .diarizing else { return }
        mplog("finishAndExport: \(entries.count) entries, systemAudioBuffer: \(systemAudioBuffer.count) samples")

        let hasRemoteEntries = entries.contains { $0.speaker != "You" }
        let hasAudioData = systemAudioBuffer.count > Int(recognitionFormat.sampleRate)

        if hasRemoteEntries && hasAudioData, let startTime = recordingStartedAt {
            state = .diarizing
            statusMessage = "Analyzing speakers..."
            mplog("finishAndExport: starting diarization")

            let currentEntries = entries
            let audioData = systemAudioBuffer
            let sampleRate = recognitionFormat.sampleRate

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let results = SpeakerDiarizer.diarize(
                    entries: currentEntries,
                    audioBuffer: audioData,
                    sampleRate: sampleRate,
                    recordingStart: startTime
                )

                DispatchQueue.main.async {
                    guard let self else { return }
                    for result in results {
                        if result.originalIndex < self.entries.count {
                            self.entries[result.originalIndex].speaker = result.speaker
                        }
                    }
                    mplog("finishAndExport: diarization complete")
                    self.doExport()
                }
            }
        } else {
            doExport()
        }
    }

    private func doExport() {
        let content = ScriptExporter.makeScriptFileContent(
            startedAt: recordingStartedAt,
            endedAt: recordingEndedAt ?? Date(),
            entries: entries
        )
        finalScript = entries.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")

        do {
            let outputURL = try ScriptExporter.exportScript(content: content)
            exportedFilePath = outputURL.path
            state = .completed
            statusMessage = "Completed. Script exported."
            mplog("doExport: exported to \(outputURL.path)")
        } catch {
            setFailure("Failed to export script: \(error.localizedDescription)")
        }
    }

    private func setFailure(_ message: String) {
        state = .failed
        lastError = message
        statusMessage = "Failed: \(message)"
        mplog("FAILURE: \(message)")
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        Task { await systemAudioCapture.stop() }
        micRequest?.endAudio(); systemRequest?.endAudio()
        micTask?.cancel(); systemTask?.cancel()
        micTask = nil; systemTask = nil
        micRequest = nil; systemRequest = nil
    }

    // MARK: CMSampleBuffer -> AVAudioPCMBuffer

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        var asbd = asbdPointer.pointee
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = pcmBuffer.frameCapacity

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        let count = min(sourceBuffers.count, destinationBuffers.count)

        for idx in 0..<count {
            guard let sourceData = sourceBuffers[idx].mData,
                  let destinationData = destinationBuffers[idx].mData else {
                continue
            }
            let bytesToCopy = min(
                Int(sourceBuffers[idx].mDataByteSize),
                Int(destinationBuffers[idx].mDataByteSize)
            )
            memcpy(destinationData, sourceData, bytesToCopy)
            destinationBuffers[idx].mDataByteSize = UInt32(bytesToCopy)
        }

        return pcmBuffer
    }
}
