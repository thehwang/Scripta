import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScriptaCore
import Speech

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
    @Published var saveAudio: Bool = true

    var isRecording: Bool { state == .recording }

    var liveScript: String {
        entries.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
    }

    @Published var recognitionLanguage: String = UserDefaults.standard.string(forKey: "Scripta.recognitionLanguage") ?? "en-US" {
        didSet { UserDefaults.standard.set(recognitionLanguage, forKey: "Scripta.recognitionLanguage") }
    }

    static let supportedRecognitionLanguages: [(code: String, name: String)] = [
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("zh-Hans", "中文 (简体)"),
        ("zh-Hant", "中文 (繁體)"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
        ("fr-FR", "Français"),
        ("de-DE", "Deutsch"),
        ("es-ES", "Español"),
        ("pt-BR", "Português"),
        ("it-IT", "Italiano"),
        ("ru-RU", "Русский"),
    ]

    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private let systemAudioCapture = SystemAudioCapture()
    private let systemAppendQueue = DispatchQueue(label: "scripta.system-audio-append")
    private let audioWriteQueue = DispatchQueue(label: "scripta.audio-write")
    private let recognitionFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var micAudioFile: AVAudioFile?
    private var systemAudioFile: AVAudioFile?
    private var writerMicConverter: AVAudioConverter?
    private var micTempURL: URL?
    private var systemTempURL: URL?

    private var micRequest: SFSpeechAudioBufferRecognitionRequest?
    private var micTask: SFSpeechRecognitionTask?
    private var systemRequest: SFSpeechAudioBufferRecognitionRequest?
    private var systemTask: SFSpeechRecognitionTask?
    private var systemAudioConverter: AVAudioConverter?

    @Published private(set) var recordingStartedAt: Date?
    private var recordingEndedAt: Date?

    private var committedMicLen: Int = 0
    private var committedSystemLen: Int = 0
    private var activeMicIdx: Int?
    private var activeSystemIdx: Int?
    private var activeMicStart: Date?
    private var activeSystemStart: Date?

    private var micTaskProducedResult = false
    private var systemTaskProducedResult = false
    private var micRetryCount = 0
    private var systemRetryCount = 0
    private var micBufferCount = 0
    private static let maxRetries = 8

    private static let commitTimeSec: TimeInterval = 10
    private static let commitChars = 200
    private static let commitCharsWithPunct = 50

    // MARK: Public API

    func startRecording() async {
        guard state != .recording else { return }

        clearPreviousResult()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: recognitionLanguage))
        mplog("startRecording: using language = \(recognitionLanguage)")

        do {
            mplog("startRecording: requesting permissions...")
            try await ensurePermissions()
            mplog("startRecording: permissions OK")

            recordingStartedAt = Date()
            recordingEndedAt = nil
            state = .recording
            statusMessage = "Recording — dual channel (You + Remote)..."

            try await beginAppleSpeechPipeline()

            startAudioWriters()
            mplog("startRecording: pipeline started, state = recording")
        } catch let error as SystemAudioCapture.CaptureError where error == .permissionDenied {
            recordingStartedAt = nil
            state = .idle
            statusMessage = "Screen Recording permission required. Open System Settings → Privacy & Security → Screen Recording → add Scripta."
            lastError = error.localizedDescription
            mplog("startRecording: screen recording permission denied")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } catch {
            mplog("startRecording FAILED: \(error.localizedDescription)")
            recordingStartedAt = nil
            state = .idle
            lastError = error.localizedDescription
            statusMessage = error.localizedDescription
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
        micRetryCount = 0; systemRetryCount = 0; micBufferCount = 0
        micTask?.cancel(); micTask = nil; micRequest = nil
        systemTask?.cancel(); systemTask = nil; systemRequest = nil
        systemAudioConverter = nil
        micAudioFile = nil; systemAudioFile = nil
        writerMicConverter = nil
        micTempURL = nil; systemTempURL = nil
        Task { await systemAudioCapture.stop() }
    }

    private func ensurePermissions() async throws {
        mplog("ensurePermissions: checking mic...")
        var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        mplog("ensurePermissions: mic status = \(micStatus.rawValue)")

        if micStatus == .notDetermined {
            mplog("ensurePermissions: requesting mic access...")
            let granted = await withTaskTimeout(seconds: 15) {
                await AVCaptureDevice.requestAccess(for: .audio)
            } ?? false
            micStatus = granted ? .authorized : AVCaptureDevice.authorizationStatus(for: .audio)
            mplog("ensurePermissions: mic after request = \(micStatus.rawValue), granted=\(granted)")
        }

        if micStatus == .denied || micStatus == .restricted {
            mplog("ensurePermissions: mic denied, opening Settings...")
            await MainActor.run {
                lastError = "Microphone access denied."
                statusMessage = "Open System Settings → Privacy & Security → Microphone → toggle ON for Scripta"
            }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                await MainActor.run { NSWorkspace.shared.open(url) }
            }
            throw NSError(domain: "Scripta", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone denied. Open System Settings → Privacy & Security → Microphone and enable Scripta."])
        }

        mplog("ensurePermissions: checking speech...")
        var speechStatus = SFSpeechRecognizer.authorizationStatus()
        mplog("ensurePermissions: speech status = \(speechStatus.rawValue)")

        if speechStatus == .notDetermined {
            mplog("ensurePermissions: requesting speech access...")
            speechStatus = await withTaskTimeout(seconds: 8) {
                await withCheckedContinuation { cont in
                    SFSpeechRecognizer.requestAuthorization { s in cont.resume(returning: s) }
                }
            } ?? .denied
            mplog("ensurePermissions: speech request result = \(speechStatus.rawValue)")
        }

        if speechStatus == .denied || speechStatus == .restricted {
            mplog("ensurePermissions: speech denied, opening System Settings...")
            await MainActor.run {
                lastError = "Speech Recognition access denied."
                statusMessage = "Open System Settings → Privacy & Security → Speech Recognition → toggle ON for Scripta"
            }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                await MainActor.run { NSWorkspace.shared.open(url) }
            }
            throw NSError(domain: "Scripta", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech Recognition not authorized. Open System Settings → Privacy & Security → Speech Recognition, find Scripta, and toggle it ON."])
        }
        mplog("ensurePermissions: all OK (mic=notDetermined will be handled by engine)")
    }

    private func withTaskTimeout<T>(seconds: TimeInterval, operation: @escaping () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
            if let first = await group.next() ?? nil {
                group.cancelAll()
                return first
            }
            group.cancelAll()
            return nil
        }
    }

    // MARK: Apple Speech Pipeline

    private func beginAppleSpeechPipeline() async throws {
        guard let speechRecognizer else {
            throw NSError(domain: "Scripta", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognizer could not be created for '\(recognitionLanguage)'."])
        }
        if !speechRecognizer.isAvailable || !speechRecognizer.supportsOnDeviceRecognition {
            let langName = Self.supportedRecognitionLanguages.first { $0.code == recognitionLanguage }?.name ?? recognitionLanguage
            throw NSError(domain: "Scripta", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "\(langName) speech model not downloaded. Go to System Settings → Keyboard → Dictation → Languages to download it."])
        }

        let micReq = SFSpeechAudioBufferRecognitionRequest()
        micReq.shouldReportPartialResults = true
        micReq.requiresOnDeviceRecognition = true
        micReq.addsPunctuation = true
        micRequest = micReq

        try startAudioEngineWithRetry(request: micReq)

        micTask = speechRecognizer.recognitionTask(with: micReq) { [weak self] result, error in
            self?.handleRecognitionResult(result: result, error: error, speaker: "You")
        }

        let sysReq = SFSpeechAudioBufferRecognitionRequest()
        sysReq.shouldReportPartialResults = true
        sysReq.requiresOnDeviceRecognition = true
        sysReq.addsPunctuation = true
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

    private func startAudioEngineWithRetry(request: SFSpeechAudioBufferRecognitionRequest) throws {
        audioEngine.stop()
        audioEngine.reset()

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        let hwFormat = inputNode.inputFormat(forBus: 0)
        mplog("Mic hardware format: rate=\(hwFormat.sampleRate) ch=\(hwFormat.channelCount) bits=\(hwFormat.streamDescription.pointee.mBitsPerChannel)")

        let hwValid = hwFormat.sampleRate > 0 && hwFormat.channelCount > 0

        if !hwValid {
            mplog("Hardware format invalid (rate=0/ch=0) — microphone not accessible to this process")

            inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            audioEngine.reset()

            mplog("Trying nil-default strategy as last resort...")
            do {
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                    self?.micRequest?.append(buffer)
                    self?.writeMicAudio(buffer)
                }
                audioEngine.prepare()
                try audioEngine.start()
                mplog("Audio engine started with nil-default")
                return
            } catch {
                mplog("nil-default failed: \(error.localizedDescription)")
            }

            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            throw NSError(
                domain: "Scripta", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Microphone not accessible. On macOS 15, try: open the app via double-click (not Terminal), or build from Xcode. Go to System Settings → Privacy & Security → Microphone to check."]
            )
        }

        let strategies: [(String, AVAudioFormat?)] = buildTapStrategies(hwFormat: hwFormat)

        var lastError: Error?
        for (label, tapFormat) in strategies {
            inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            audioEngine.reset()

            mplog("Trying tap strategy: \(label) → format=\(tapFormat?.description ?? "nil")")
            do {
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
                    guard let self else { return }
                    self.micRequest?.append(buffer)
                    self.writeMicAudio(buffer)
                    self.micBufferCount += 1
                    if self.micBufferCount == 1 || self.micBufferCount == 10 || self.micBufferCount == 50 {
                        mplog("Mic tap: buffer #\(self.micBufferCount) frames=\(buffer.frameLength) rate=\(buffer.format.sampleRate)")
                    }
                }
                audioEngine.prepare()
                try audioEngine.start()
                mplog("Audio engine started with strategy: \(label)")
                return
            } catch {
                mplog("Strategy '\(label)' failed: \(error.localizedDescription)")
                lastError = error
                inputNode.removeTap(onBus: 0)
            }
        }

        throw lastError ?? NSError(
            domain: "Scripta", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Could not start audio engine. Make sure no other app is using the microphone."]
        )
    }

    private func buildTapStrategies(hwFormat: AVAudioFormat) -> [(String, AVAudioFormat?)] {
        var strategies: [(String, AVAudioFormat?)] = []

        strategies.append(("hardware-native", hwFormat))

        if hwFormat.channelCount > 1 || hwFormat.commonFormat != .pcmFormatFloat32 {
            if let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: hwFormat.sampleRate,
                                        channels: 1, interleaved: false) {
                strategies.append(("mono-float32-hwrate", mono))
            }
        }

        strategies.append(("nil-default", nil))

        return strategies
    }

    // MARK: Recognition result handling

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?, speaker: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isMic = speaker == "You"

            if let result {
                if isMic { self.micTaskProducedResult = true; self.micRetryCount = 0 }
                else { self.systemTaskProducedResult = true; self.systemRetryCount = 0 }

                let text = result.bestTranscription.formattedString
                mplog("[\(speaker)] result (isFinal=\(result.isFinal)) len=\(text.count): \(String(text.prefix(80)))")
                self.processPartialResult(result, speaker: speaker)

                if result.isFinal {
                    self.handleTaskFinished(speaker: speaker, willRestart: true)
                }
            }

            if let error {
                let desc = error.localizedDescription
                mplog("[\(speaker)] error: \(desc) (state=\(self.state.rawValue), micBufs=\(self.micBufferCount))")
                let produced = isMic ? self.micTaskProducedResult : self.systemTaskProducedResult

                if desc.contains("access assets") || desc.contains("not available") {
                    let langName = Self.supportedRecognitionLanguages.first { $0.code == self.recognitionLanguage }?.name ?? self.recognitionLanguage
                    self.statusMessage = "\(langName) model downloading or unavailable. Go to Settings → Keyboard → Dictation to download."
                }

                if self.state == .recording && produced {
                    mplog("[\(speaker)] task had results → restart")
                    self.handleTaskFinished(speaker: speaker, willRestart: true)
                } else if self.state == .recording {
                    let retryCount = isMic ? self.micRetryCount : self.systemRetryCount
                    if retryCount < Self.maxRetries {
                        if isMic { self.micRetryCount += 1 } else { self.systemRetryCount += 1 }
                        let delay = Double(retryCount + 1) * 0.5
                        mplog("[\(speaker)] task had NO results → retry #\(retryCount + 1) in \(delay)s")
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self, self.state == .recording else { return }
                            self.restartRecognitionTask(speaker: speaker)
                        }
                    } else {
                        mplog("[\(speaker)] task had NO results → max retries reached, giving up")
                        self.statusMessage = "\(speaker) channel: speech recognition not responding. Check System Settings → Keyboard → Dictation to ensure the \(self.recognitionLanguage) model is downloaded."
                    }
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
                c == "." || c == "!" || c == "?" ||
                c == "\u{3002}" || c == "\u{FF01}" || c == "\u{FF1F}" || // 。！？
                c == "\u{FF0C}" || c == "\u{3001}"                       // ，、
            }
            let isCJK = uncommitted.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
            let punctThreshold = isCJK ? 15 : Self.commitCharsWithPunct
            let lengthThreshold = isCJK ? 60 : Self.commitChars
            let timeThreshold = isCJK ? 12 : Int(Self.commitTimeSec)

            if elapsed > TimeInterval(timeThreshold) && uncommitted.count > (isCJK ? 8 : 30) {
                shouldCommit = true
            } else if hasPunct && uncommitted.count > punctThreshold {
                shouldCommit = true
            } else if uncommitted.count > lengthThreshold {
                shouldCommit = true
            }
        }

        if shouldCommit {
            if let idx = activeIdx, idx < entries.count {
                entries[idx].text = uncommitted
                entries[idx].isCommitted = true
            } else {
                entries.append(TranscriptEntry(speaker: speaker, text: uncommitted, isCommitted: true))
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
        let activeIdx = isMic ? activeMicIdx : activeSystemIdx
        if let idx = activeIdx, idx < entries.count {
            entries[idx].isCommitted = true
        }
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
        newReq.addsPunctuation = true

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

    // MARK: Audio File Writers

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
            mplog("Audio writer: mic → \(micTempURL!.lastPathComponent)")
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
            mplog("Audio writer: system → \(systemTempURL!.lastPathComponent)")
        } catch {
            mplog("Failed to create system audio file: \(error)")
        }
    }

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
        let translatedContent = ScriptExporter.makeTranslatedContent(
            startedAt: recordingStartedAt,
            endedAt: recordingEndedAt ?? Date(),
            entries: entries
        )
        finalScript = entries.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")

        do {
            let sessionDir = try ScriptExporter.exportSession(
                content: content,
                translatedContent: translatedContent,
                micAudioURL: micAudioURL,
                systemAudioURL: systemAudioURL,
                startedAt: recordingStartedAt,
                entryCount: entries.count,
                language: recognitionLanguage
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
