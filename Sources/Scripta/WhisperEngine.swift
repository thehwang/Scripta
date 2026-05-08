import AVFoundation
import CWhisper
import Foundation
import ScriptaCore

final class WhisperEngine {
    private var ctx: OpaquePointer?
    private let processingQueue = DispatchQueue(label: "scripta.whisper", qos: .userInitiated)

    private var sampleBuffer: [Float] = []
    private let bufferLock = NSLock()

    private let chunkDuration: TimeInterval = 5.0
    private let overlapDuration: TimeInterval = 1.0
    private let sampleRate: Int = 16_000

    private var chunkSamples: Int { Int(chunkDuration * Double(sampleRate)) }
    private var overlapSamples: Int { Int(overlapDuration * Double(sampleRate)) }

    private(set) var isLoaded = false
    private var isProcessing = false

    var onTranscript: ((String) -> Void)?

    static let defaultModelName = "ggml-base.bin"

    static var modelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Scripta/models")
    }

    static var defaultModelPath: URL {
        modelDirectory.appendingPathComponent(defaultModelName)
    }

    static var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: defaultModelPath.path)
    }

    init() {}

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    func loadModel(at path: URL? = nil) -> Bool {
        let modelPath = path ?? Self.defaultModelPath
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            mplog("WhisperEngine: model not found at \(modelPath.path)")
            return false
        }

        if let ctx { whisper_free(ctx); self.ctx = nil }

        var params = whisper_context_default_params()
        params.use_gpu = true

        guard let newCtx = whisper_init_from_file_with_params(modelPath.path, params) else {
            mplog("WhisperEngine: failed to load model at \(modelPath.path)")
            return false
        }

        ctx = newCtx
        isLoaded = true
        mplog("WhisperEngine: model loaded from \(modelPath.lastPathComponent)")
        return true
    }

    func appendSamples(_ samples: UnsafePointer<Float>, count: Int) {
        bufferLock.lock()
        sampleBuffer.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        let ready = sampleBuffer.count >= chunkSamples
        bufferLock.unlock()

        if ready && !isProcessing {
            processNextChunk()
        }
    }

    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData?[0] else { return }
        appendSamples(floatData, count: Int(buffer.frameLength))
    }

    func flush() {
        bufferLock.lock()
        let remaining = sampleBuffer
        sampleBuffer.removeAll()
        bufferLock.unlock()

        guard !remaining.isEmpty, remaining.count > sampleRate / 2 else { return }
        transcribeChunk(remaining)
    }

    func reset() {
        bufferLock.lock()
        sampleBuffer.removeAll()
        bufferLock.unlock()
    }

    private func processNextChunk() {
        bufferLock.lock()
        guard sampleBuffer.count >= chunkSamples else {
            bufferLock.unlock()
            return
        }

        let chunk = Array(sampleBuffer.prefix(chunkSamples))
        let keepFrom = chunkSamples - overlapSamples
        sampleBuffer.removeFirst(keepFrom)
        bufferLock.unlock()

        transcribeChunk(chunk)
    }

    private func transcribeChunk(_ samples: [Float]) {
        guard let ctx, isLoaded else { return }
        isProcessing = true

        processingQueue.async { [weak self] in
            guard let self else { return }

            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.print_realtime = false
            params.print_progress = false
            params.print_timestamps = false
            params.print_special = false
            params.no_context = true
            params.single_segment = false
            let langStr = strdup("en")
            params.language = UnsafePointer(langStr)
            params.n_threads = 4

            let start = CFAbsoluteTimeGetCurrent()
            let result = samples.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - start

            free(langStr)

            if result == 0 {
                let nSegments = whisper_full_n_segments(ctx)
                var text = ""
                for i in 0..<nSegments {
                    if let seg = whisper_full_get_segment_text(ctx, i) {
                        text += String(cString: seg)
                    }
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)

                if !text.isEmpty && !Self.isNoiseSegment(text) {
                    mplog("WhisperEngine: \(nSegments) segments in \(String(format: "%.2f", elapsed))s: \(String(text.prefix(100)))")
                    DispatchQueue.main.async {
                        self.onTranscript?(text)
                    }
                }
            } else {
                mplog("WhisperEngine: whisper_full failed with code \(result)")
            }

            self.isProcessing = false

            self.bufferLock.lock()
            let moreReady = self.sampleBuffer.count >= self.chunkSamples
            self.bufferLock.unlock()
            if moreReady { self.processNextChunk() }
        }
    }

    private static func isNoiseSegment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { return true }
        if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") { return true }
        let noisePatterns = ["music", "silence", "blank", "no speech", "thank you"]
        let lower = trimmed.lowercased()
        for p in noisePatterns where lower.contains(p) { return true }
        return false
    }
}
