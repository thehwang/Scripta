import AVFoundation
import CoreMedia
import Foundation
import MeetingPilotCore
import Speech

enum TranscriptionEngine: String, CaseIterable {
    case apple = "Apple Speech"
    case whisper = "Whisper"
}

final class MeetingRecorder: NSObject, ObservableObject {
    enum State: String {
        case idle = "Idle"
        case recording = "Recording"
        case transcribing = "Transcribing"
        case completed = "Completed"
        case failed = "Failed"
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var statusMessage: String = "Ready to start meeting capture."
    @Published var entries: [TranscriptEntry] = []
    @Published private(set) var finalScript: String = ""
    @Published private(set) var exportedFilePath: String = ""
    @Published private(set) var lastError: String = ""
    @Published var transcriptionEngine: TranscriptionEngine = .apple
    @Published var saveAudio: Bool = true

    var isRecording: Bool { state == .recording }

    var liveScript: String {
        entries.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
    }

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let systemAudioCapture = SystemAudioCapture()
    private let systemAppendQueue = DispatchQueue(label: "meetingpilot.system-audio-append")
    private let audioWriteQueue = DispatchQueue(label: "meetingpilot.audio-write")
    private let recognitionFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    // Audio file writers (AAC M4A via AVAudioFile)
    private var micAudioFile: AVAudioFile?
    private var systemAudioFile: AVAudioFile?
    private var writerMicConverter: AVAudioConverter?
    private var micTempURL: URL?
    private var systemTempURL: URL?

    // Apple Speech engine state
    private var micRequest: SFSpeechAudioBufferRecognitionRequest?
    private var micTask: SFSpeechRecognitionTask?
    private var systemRequest: SFSpeechAudioBufferRecognitionRequest?
    private var systemTask: SFSpeechRecognitionTask?
    private var systemAudioConverter: AVAudioConverter?

    // Whisper engine state
    private var whisperTranscriber: WhisperTranscriber?

    private var recordingStartedAt: Date?
    private var recordingEndedAt: Date?

    // Per-speaker accumulation state (Apple Speech engine).
    private var committedMicLen: Int = 0
    private var committedSystemLen: Int = 0
    private var activeMicIdx: Int?
    private var activeSystemIdx: Int?
    private var activeMicStart: Date?
    private var activeSystemStart: Date?

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
            mplog("startRecording: permissions OK, engine=\(transcriptionEngine.rawValue)")

            switch transcriptionEngine {
            case .apple:
                try await beginAppleSpeechPipeline()
            case .whisper:
                try await beginWhisperPipeline()
            }

            startAudioWriters()
            recordingStartedAt = Date()
            recordingEndedAt = nil
            state = .recording
            statusMessage = "Recording — dual channel (You + Remote) via \(transcriptionEngine.rawValue)..."
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

        switch transcriptionEngine {
        case .apple:
            micRequest?.endAudio()
            systemRequest?.endAudio()
        case .whisper:
            whisperTranscriber?.stop()
        }

        Task { await systemAudioCapture.stop() }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self.state == .transcribing {
                mplog("stopRecording: timeout — forcing export")
                self.finishAndExport()
            }
        }
    }

    /// Configure Whisper transcriber with a downloaded model path.
    /// Does not change the active engine — user can switch manually.
    func loadWhisperModel(path: String) async throws {
        let transcriber = WhisperTranscriber()
        try await transcriber.load(modelPath: path)
        whisperTranscriber = transcriber
        mplog("Whisper model loaded from \(path), engine stays \(transcriptionEngine.rawValue)")
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
        micAudioFile = nil; systemAudioFile = nil
        writerMicConverter = nil
        micTempURL = nil; systemTempURL = nil
        Task { await systemAudioCapture.stop() }
    }

    private func ensurePermissions() async throws {
        // Microphone: check status first, only prompt when .notDetermined
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw NSError(domain: "MeetingPilot", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied. Grant it in System Settings → Privacy & Security → Microphone."])
            }
        default:
            throw NSError(domain: "MeetingPilot", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied. Grant it in System Settings → Privacy & Security → Microphone."])
        }

        // Speech recognition: only needed for Apple engine, check status first
        if transcriptionEngine == .apple {
            let speechStatus = SFSpeechRecognizer.authorizationStatus()
            switch speechStatus {
            case .authorized:
                break
            case .notDetermined:
                let status = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { status in
                        continuation.resume(returning: status)
                    }
                }
                guard status == .authorized else {
                    throw NSError(domain: "MeetingPilot", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission denied. Grant it in System Settings → Privacy & Security → Speech Recognition."])
                }
            default:
                throw NSError(domain: "MeetingPilot", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission denied. Grant it in System Settings → Privacy & Security → Speech Recognition."])
            }
        }
    }

    // MARK: Whisper Pipeline

    private func beginWhisperPipeline() async throws {
        guard let transcriber = whisperTranscriber else {
            throw NSError(domain: "MeetingPilot", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Whisper model not loaded. Please download a model first."])
        }

        transcriber.onTranscription = { [weak self] text, channel in
            guard let self else { return }
            let speaker = channel == .mic ? "You" : "Remote"
            self.entries.append(TranscriptEntry(speaker: speaker, text: text))
        }

        // Mic channel
        let inputNode = audioEngine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)

        let targetRate = recognitionFormat.sampleRate
        var micConverter: AVAudioConverter?
        if micFormat.sampleRate != targetRate || micFormat.channelCount != 1 {
            micConverter = AVAudioConverter(from: micFormat, to: recognitionFormat)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if let converter = micConverter {
                if let converted = self.convertBuffer(buffer, using: converter) {
                    self.writeMicAudio(converted)
                    transcriber.appendAudio(converted, channel: .mic)
                }
            } else {
                self.writeMicAudio(buffer)
                transcriber.appendAudio(buffer, channel: .mic)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        // System audio channel
        systemAudioCapture.onAudioSampleBuffer = { [weak self] sampleBuffer in
            self?.appendSystemAudioForWhisper(sampleBuffer)
        }
        systemAudioCapture.onError = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.state == .recording || self.state == .transcribing else { return }
                self.setFailure("System audio capture failed: \(error.localizedDescription)")
            }
        }
        try await systemAudioCapture.start()
        mplog("Whisper pipeline: system audio capture started")

        transcriber.start()
        mplog("Whisper pipeline: both channels active")
    }

    private func appendSystemAudioForWhisper(_ sampleBuffer: CMSampleBuffer) {
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

        writeSystemAudio(buffer)
        whisperTranscriber?.appendAudio(buffer, channel: .system)
    }

    private func convertBuffer(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
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

    // MARK: Apple Speech Pipeline

    private func beginAppleSpeechPipeline() async throws {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw NSError(domain: "MeetingPilot", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is not available."])
        }

        let micReq = SFSpeechAudioBufferRecognitionRequest()
        micReq.shouldReportPartialResults = true
        micReq.requiresOnDeviceRecognition = true
        micRequest = micReq

        let inputNode = audioEngine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            self?.micRequest?.append(buffer)
            self?.writeMicAudio(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        micTask = speechRecognizer.recognitionTask(with: micReq) { [weak self] result, error in
            self?.handleRecognitionResult(result: result, error: error, speaker: "You")
        }

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
        mplog("Apple Speech pipeline: system audio capture started")

        systemTask = speechRecognizer.recognitionTask(with: sysReq) { [weak self] result, error in
            self?.handleRecognitionResult(result: result, error: error, speaker: "Remote")
        }
        mplog("Apple Speech pipeline: both recognition tasks created")
    }

    // MARK: Apple Speech - Recognition result handling

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?, speaker: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isMic = speaker == "You"

            if let result {
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
                    mplog("[\(speaker)] task had results → restart")
                    self.handleTaskFinished(speaker: speaker, willRestart: true)
                } else if self.state == .recording {
                    mplog("[\(speaker)] task had NO results → skip restart")
                } else if self.state == .transcribing {
                    self.handleTaskFinished(speaker: speaker, willRestart: false)
                }
            }
        }
    }

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

    private func freezeActiveEntry(speaker: String) {
        let isMic = speaker == "You"
        clearActive(isMic: isMic)
        setCommitted(0, isMic: isMic)
    }

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

    // MARK: System audio -> Apple Speech recognition request

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

        writeSystemAudio(buffer)

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

    // MARK: Audio File Writers (AVAudioFile — handles timestamps & encoding)

    private static let audioFileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 48_000,
    ]

    private func startAudioWriters() {
        guard saveAudio else { return }
        let tmp = FileManager.default.temporaryDirectory

        micTempURL = tmp.appendingPathComponent("mp_mic_\(UUID().uuidString).m4a")
        systemTempURL = tmp.appendingPathComponent("mp_sys_\(UUID().uuidString).m4a")

        do {
            let file = try AVAudioFile(
                forWriting: micTempURL!,
                settings: Self.audioFileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            micAudioFile = file
            writerMicConverter = AVAudioConverter(
                from: audioEngine.inputNode.outputFormat(forBus: 0),
                to: file.processingFormat
            )
            mplog("Audio writer: mic → \(micTempURL!.lastPathComponent) procFmt=\(file.processingFormat)")
        } catch {
            mplog("Failed to create mic audio file: \(error)")
        }

        do {
            let file = try AVAudioFile(
                forWriting: systemTempURL!,
                settings: Self.audioFileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            systemAudioFile = file
            mplog("Audio writer: system → \(systemTempURL!.lastPathComponent) procFmt=\(file.processingFormat)")
        } catch {
            mplog("Failed to create system audio file: \(error)")
        }
    }

    /// Convert buffer to the file's processingFormat, then write on the serial queue.
    private func writeMicAudio(_ buffer: AVAudioPCMBuffer) {
        guard let file = micAudioFile, let converter = writerMicConverter else { return }

        let outFormat = file.processingFormat
        let outBuf: AVAudioPCMBuffer

        if buffer.format == outFormat {
            outBuf = buffer
        } else {
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate + 32
            )
            guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: max(frameCount, 32)) else { return }
            var provided = false
            var err: NSError?
            let status = converter.convert(to: output, error: &err) { _, outStatus in
                if provided { outStatus.pointee = .noDataNow; return nil }
                provided = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, output.frameLength > 0 else { return }
            outBuf = output
        }

        audioWriteQueue.async {
            do { try file.write(from: outBuf) }
            catch { mplog("Mic write error: \(error)") }
        }
    }

    /// System audio is already converted to recognitionFormat; re-convert to file
    /// processingFormat if they differ.
    private func writeSystemAudio(_ buffer: AVAudioPCMBuffer) {
        guard let file = systemAudioFile else { return }

        let outFormat = file.processingFormat
        let outBuf: AVAudioPCMBuffer

        if buffer.format == outFormat {
            outBuf = buffer
        } else {
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate + 32
            )
            guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: max(frameCount, 32)) else { return }

            let converter = AVAudioConverter(from: buffer.format, to: outFormat)!
            var provided = false
            var err: NSError?
            let status = converter.convert(to: output, error: &err) { _, outStatus in
                if provided { outStatus.pointee = .noDataNow; return nil }
                provided = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, output.frameLength > 0 else { return }
            outBuf = output
        }

        audioWriteQueue.async {
            do { try file.write(from: outBuf) }
            catch { mplog("System write error: \(error)") }
        }
    }

    private func stopAudioWriters(completion: @escaping (URL?, URL?) -> Void) {
        guard saveAudio else {
            completion(nil, nil)
            return
        }

        let micURL = micTempURL
        let sysURL = systemTempURL

        audioWriteQueue.async { [weak self] in
            self?.micAudioFile = nil
            self?.systemAudioFile = nil
            self?.writerMicConverter = nil

            let fm = FileManager.default
            let validMic: URL? = micURL.flatMap { url in
                guard let sz = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, sz > 1024 else { return nil }
                return url
            }
            let validSys: URL? = sysURL.flatMap { url in
                guard let sz = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, sz > 1024 else { return nil }
                return url
            }

            DispatchQueue.main.async {
                mplog("Audio writers stopped: mic=\(validMic?.lastPathComponent ?? "nil") sys=\(validSys?.lastPathComponent ?? "nil")")
                completion(validMic, validSys)
            }
        }
    }

    // MARK: Finish & export

    private func finishAndExport() {
        guard state != .completed else { return }
        mplog("finishAndExport: \(entries.count) entries")

        stopAudioWriters { [weak self] micURL, sysURL in
            self?.doExport(micAudioURL: micURL, systemAudioURL: sysURL)
        }
    }

    private func doExport(micAudioURL: URL?, systemAudioURL: URL?) {
        let content = ScriptExporter.makeScriptFileContent(
            startedAt: recordingStartedAt,
            endedAt: recordingEndedAt ?? Date(),
            entries: entries
        )
        finalScript = entries.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")

        do {
            let sessionDir = try ScriptExporter.exportSession(
                content: content,
                micAudioURL: micAudioURL,
                systemAudioURL: systemAudioURL,
                startedAt: recordingStartedAt
            )
            exportedFilePath = sessionDir.path
            state = .completed
            let hasAudio = micAudioURL != nil || systemAudioURL != nil
            statusMessage = "Completed. Exported to session folder\(hasAudio ? " (with audio)" : "")."
            mplog("doExport: exported to \(sessionDir.path)")
        } catch {
            setFailure("Failed to export: \(error.localizedDescription)")
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
        whisperTranscriber?.stop()
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

