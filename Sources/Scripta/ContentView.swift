import AVFoundation
import ScriptaCore
import Speech
import SwiftUI

// MARK: - Color Theme

private enum Theme {
    static let bg = Color(red: 0.071, green: 0.075, blue: 0.090)
    static let surface = Color(red: 0.118, green: 0.122, blue: 0.137)
    static let surfaceHigh = Color(red: 0.180, green: 0.185, blue: 0.205)
    static let border = Color.white.opacity(0.10)
    static let borderLight = Color.white.opacity(0.15)
    static let accent = Color(red: 0.35, green: 0.60, blue: 1.0)
    static let accentSoft = Color(red: 0.72, green: 0.82, blue: 1.0)
    static let textPrimary = Color(red: 0.94, green: 0.94, blue: 0.96)
    static let textSecondary = Color(red: 0.65, green: 0.67, blue: 0.72)
    static let textMuted = Color(red: 0.48, green: 0.50, blue: 0.55)
    static let red = Color(red: 0.576, green: 0.0, blue: 0.039)
    static let redBright = Color(red: 1.0, green: 0.706, blue: 0.671)
}

// MARK: - Display Mode

enum DisplayMode: String {
    case full
    case minimal
}

extension Notification.Name {
    static let displayModeChanged = Notification.Name("Scripta.displayModeChanged")
    static let showMeetingHistory = Notification.Name("Scripta.showMeetingHistory")
}

// MARK: - Main View

struct ContentView: View {
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var summaryModelManager: SummaryModelManager
    @ObservedObject var translationService: TranslationService
    @ObservedObject var meetingStore: MeetingStore
    var onOpenModelSettings: (() -> Void)?

    @StateObject private var summaryService = SummaryService()
    @State private var hasMicPermission = false
    @State private var now = Date()
    @State private var showSummary = false
    @State private var showChatPanel = false
    @State private var showHistoryPanel = false
    @AppStorage("Scripta.displayMode") private var displayMode: String = DisplayMode.full.rawValue
    @AppStorage("Scripta.fontScale") private var fontScale: Double = 1.0
    @AppStorage("Scripta.recordingDisclaimerAccepted") private var disclaimerAccepted = false
    @State private var showRecordingDisclaimer = false
    @State private var whisperModelState: WhisperModelState = WhisperEngine.isModelDownloaded ? .ready : .missing
    @State private var whisperDownloadProgress: String = ""

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum WhisperModelState { case missing, downloading, ready, failed }

    private var isMinimal: Bool { displayMode == DisplayMode.minimal.rawValue }

    private var liveTranscriptText: String {
        recorder.entries.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
    }

    private let fontScaleMin: Double = 0.7
    private let fontScaleMax: Double = 1.8
    private let fontScaleStep: Double = 0.1

    private func scaled(_ baseSize: CGFloat) -> CGFloat {
        baseSize * CGFloat(fontScale)
    }

    private func requestStartRecording() {
        if disclaimerAccepted {
            Task { @MainActor in await recorder.startRecording() }
        } else {
            showRecordingDisclaimer = true
        }
    }

    var body: some View {
        Group {
            if isMinimal {
                minimalBody
            } else {
                fullBody
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: recorder.entries.count) { translateCommittedEntries() }
        .onChange(of: recorder.state) {
            if recorder.state == .completed && summaryModelManager.isReady {
                showSummary = true
            }
        }
        .task { await summaryModelManager.checkConnection() }
        .onAppear { refreshPermissionStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
        .onReceive(timer) { now = $0; translateCommittedEntries() }
        .onReceive(NotificationCenter.default.publisher(for: .showMeetingHistory)) { _ in
            showHistoryPanel = true
        }
        .modifier(TranslationTaskModifier(translationService: translationService))
        .alert("Recording Notice", isPresented: $showRecordingDisclaimer) {
            Button("I Understand & Agree") {
                disclaimerAccepted = true
                Task { @MainActor in await recorder.startRecording() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Recording conversations may be subject to local consent laws. In many jurisdictions, all participants must be informed and consent before being recorded.\n\nYou are solely responsible for complying with applicable laws. By proceeding, you acknowledge this responsibility.")
        }
    }

    // MARK: - Full Mode Body

    private var fullBody: some View {
        HSplitView {
            ZStack {
                Theme.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    Divider().background(Theme.border)

                    VStack(spacing: 0) {
                        if !hasMicPermission && recorder.state == .idle {
                            permissionBanner.padding(.horizontal, 20).padding(.top, 16)
                        }
                        if !summaryModelManager.isReady && recorder.state == .idle {
                            aiModelBanner.padding(.horizontal, 20).padding(.top, 16)
                        }
                        if whisperModelState != .ready && recorder.state == .idle {
                            whisperModelBanner.padding(.horizontal, 20).padding(.top, 16)
                        }
                        statusStrip.padding(.horizontal, 20).padding(.top, 16)
                        transcriptPanel.padding(.horizontal, 20).padding(.top, 12)

                        if showSummary || summaryService.isGenerating || !summaryService.streamingText.isEmpty {
                            summaryPanel.padding(.horizontal, 20).padding(.top, 8)
                        }

                        exportStrip.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)
                    }

                    Spacer(minLength: 0)
                    bottomBar
                }
            }
            .frame(minWidth: 560)

            if showChatPanel {
                ChatPanel(
                    transcriptText: liveTranscriptText,
                    modelName: summaryModelManager.selectedModel,
                    isModelReady: summaryModelManager.isReady
                )
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 450)
            }
        }
        .frame(minWidth: showChatPanel ? 900 : 760, minHeight: 680)
        .sheet(isPresented: $showHistoryPanel) {
            HistoryPanel(
                store: meetingStore,
                modelName: summaryModelManager.selectedModel,
                isModelReady: summaryModelManager.isReady,
                onDismiss: { showHistoryPanel = false }
            )
            .frame(minWidth: 600, minHeight: 500)
        }
    }

    // MARK: - Minimal Mode Body (Live Captions Style)

    private var lastEntryText: String {
        recorder.entries.last?.text ?? ""
    }

    private var minimalBody: some View {
        VStack(spacing: 0) {
            minimalCaptionArea
            minimalControlBar
        }
        .background(Color.black.opacity(0.82))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private var minimalCaptionArea: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer(minLength: 0)
            let recentEntries = Array(recorder.entries.suffix(4))
            if recentEntries.isEmpty {
                Text(recorder.isRecording ? "Listening..." : "Press ● to start")
                    .font(.system(size: scaled(15), weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(recentEntries.enumerated()), id: \.element.id) { idx, entry in
                    minimalEntryRow(entry, isLatest: idx == recentEntries.count - 1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = recorder.entries.last {
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private func minimalEntryRow(_ entry: TranscriptEntry, isLatest: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.speaker)
                .font(.system(size: scaled(12), weight: .bold))
                .foregroundStyle(speakerColor(entry.speaker))
                .frame(width: scaled(52), alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.system(size: scaled(15), weight: isLatest ? .medium : .regular))
                    .foregroundStyle(isLatest ? .white : Color.white.opacity(0.65))
                    .lineSpacing(scaled(2))

                if let translated = entry.translatedText, shouldShowTranslation {
                    Text(translated)
                        .font(.system(size: scaled(14)))
                        .foregroundStyle(Theme.textSecondary.opacity(0.85))
                }
            }
        }
        .padding(.vertical, 3)
        .opacity(isLatest ? 1.0 : 0.7)
    }

    private var minimalControlBar: some View {
        HStack(spacing: 12) {
            if recorder.isRecording {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .modifier(PulseAnimation())
                    Text(formattedDuration)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.red.opacity(0.9))
                }
            }

            fontSizeControlsCompact

            Spacer()

            if recorder.isRecording {
                Button {
                    recorder.stopRecording()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.red.opacity(0.8), in: Circle())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    requestStartRecording()
                } label: {
                    Image(systemName: "record.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(recorder.state == .transcribing)
            }

            Button {
                switchToMode(.full)
            } label: {
                Image(systemName: "rectangle.expand.vertical")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Switch to full view")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.3))
    }

    private func refreshPermissionStatus() {
        hasMicPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func switchToMode(_ mode: DisplayMode) {
        displayMode = mode.rawValue
        NotificationCenter.default.post(name: .displayModeChanged, object: mode)
    }

    private func increaseFontScale() {
        fontScale = min(fontScaleMax, fontScale + fontScaleStep)
    }

    private func decreaseFontScale() {
        fontScale = max(fontScaleMin, fontScale - fontScaleStep)
    }

    private func resetFontScale() {
        fontScale = 1.0
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 0) {
            Text("Scripta")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(version)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.leading, 4)
            }

            Divider().frame(height: 14).padding(.horizontal, 12)

            if recorder.isRecording {
                recordingBadge
            } else {
                Text(recorder.state.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(.uppercase)
                    .tracking(1)
            }

            Spacer()

            if !recorder.exportedFilePath.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                    Text(recorder.exportedFilePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: 280)
                .padding(.trailing, 8)
            }

            Button {
                showHistoryPanel = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.04), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Meeting history")
            .padding(.trailing, 2)

            Button {
                showChatPanel.toggle()
            } label: {
                Image(systemName: showChatPanel ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                    .font(.system(size: 12))
                    .foregroundStyle(showChatPanel ? Theme.accent : Theme.textMuted)
                    .frame(width: 28, height: 28)
                    .background(showChatPanel ? Theme.accent.opacity(0.12) : Color.white.opacity(0.04), in: Circle())
            }
            .buttonStyle(.plain)
            .help(showChatPanel ? "Hide chat panel" : "Open chat panel")
            .padding(.trailing, 2)

            fontSizeControls
                .padding(.trailing, 4)

            Button {
                switchToMode(.minimal)
            } label: {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.04), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Switch to minimal captions view")
            .padding(.trailing, 4)

            aiModelBadge
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.black.opacity(0.3))
    }

    private var recordingBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 7, height: 7)
                .shadow(color: Theme.accent.opacity(0.6), radius: 4)
                .modifier(PulseAnimation())
            Text("LIVE RECORDING")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Theme.accentSoft)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.accent.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(Theme.accent.opacity(0.2), lineWidth: 0.5))
    }

    private var aiModelBadge: some View {
        Button {
            onOpenModelSettings?()
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(ollamaBadgeColor)
                    .frame(width: 6, height: 6)
                Text(ollamaBadgeLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ollamaBadgeColor.opacity(0.9))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                summaryModelManager.isReady
                    ? Color.white.opacity(0.04)
                    : ollamaBadgeColor.opacity(0.1),
                in: Capsule()
            )
            .overlay(
                summaryModelManager.isReady
                    ? nil
                    : Capsule().stroke(ollamaBadgeColor.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var ollamaBadgeColor: Color {
        switch summaryModelManager.connectionState {
        case .ready: return .green
        case .connected, .pulling: return .orange
        default: return .red
        }
    }

    private var ollamaBadgeLabel: String {
        switch summaryModelManager.connectionState {
        case .ready: return "AI Ready"
        case .connected: return "No Model"
        case .pulling: return "Pulling..."
        case .connecting: return "Connecting..."
        default: return "Ollama Offline"
        }
    }

    // MARK: - Status Strip

    private var statusStrip: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if !recorder.lastError.isEmpty {
                    Text(recorder.lastError)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.redBright)
                        .lineLimit(2)
                }
                Text(recorder.statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("DURATION")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textMuted)
                Text(formattedDuration)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
        }
    }

    private var formattedDuration: String {
        guard let start = recorder.recordingStartedAt else { return "00:00:00" }
        let ref = recorder.isRecording ? now : (recorder.recordingStartedAt ?? now)
        let elapsed = max(0, ref.timeIntervalSince(start))
        let h = Int(elapsed) / 3600
        let m = (Int(elapsed) % 3600) / 60
        let s = Int(elapsed) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    // MARK: - Permission Banner

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
            Text("Microphone permission required.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange.opacity(0.9))
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.15), lineWidth: 0.5))
    }

    // MARK: - AI Model Banner

    private var aiModelBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.accent)
                .font(.system(size: 18))

            VStack(alignment: .leading, spacing: 2) {
                Text(summaryModelManager.isConnected ? "No AI model selected" : "Ollama not connected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(summaryModelManager.isConnected
                     ? "Select or pull an AI model to get meeting summaries after recording."
                     : "Install and start Ollama to enable local AI summaries.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Button(summaryModelManager.isConnected ? "Select Model" : "Setup Ollama") {
                onOpenModelSettings?()
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.12), lineWidth: 0.5))
    }

    // MARK: - Whisper Model Banner

    private var whisperModelBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .foregroundStyle(.orange)
                .font(.system(size: 18))

            VStack(alignment: .leading, spacing: 2) {
                switch whisperModelState {
                case .missing:
                    Text("Whisper speech model required")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Download ggml-base.bin (~142 MB) for local mic transcription via whisper.cpp.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                case .downloading:
                    Text("Downloading Whisper model...")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(whisperDownloadProgress)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                case .failed:
                    Text("Download failed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.redBright)
                    Text("Check your internet connection and try again.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                case .ready:
                    EmptyView()
                }
            }

            Spacer()

            if whisperModelState == .missing || whisperModelState == .failed {
                Button("Download") { downloadWhisperModel() }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if whisperModelState == .downloading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.12), lineWidth: 0.5))
    }

    private func downloadWhisperModel() {
        whisperModelState = .downloading
        whisperDownloadProgress = "Starting download..."

        Task.detached(priority: .userInitiated) {
            let modelDir = WhisperEngine.modelDirectory
            try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
            let destURL = WhisperEngine.defaultModelPath
            let srcURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(WhisperEngine.defaultModelName)")!

            let (tempURL, response) = try await URLSession.shared.download(from: srcURL, delegate: nil)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                await MainActor.run {
                    whisperModelState = .failed
                    whisperDownloadProgress = "Server returned error."
                }
                return
            }

            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: tempURL, to: destURL)

            await MainActor.run {
                whisperModelState = .ready
                whisperDownloadProgress = ""
                _ = recorder.whisperEngine.loadModel()
            }
        }
    }

    // MARK: - Transcript Panel

    private var transcriptPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Live Transcript")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(recorder.entries.count) entries")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().background(Theme.border)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if recorder.entries.isEmpty {
                            emptyTranscriptView
                        }
                        ForEach(Array(recorder.entries.enumerated()), id: \.element.id) { index, entry in
                            entryRow(entry, isLast: index == recorder.entries.count - 1)
                                .id(entry.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: recorder.entries.count) {
                    scrollToBottom(proxy)
                }
                .onChange(of: lastEntryText) {
                    scrollToBottom(proxy)
                }
            }
        }
        .background(Theme.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 0.5))
    }

    private var emptyTranscriptView: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 28))
                .foregroundStyle(Theme.textMuted)
            Text("Transcript will appear here")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func entryRow(_ entry: TranscriptEntry, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(timeString(entry.timestamp))
                .font(.system(size: scaled(11), weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .frame(width: scaled(50), alignment: .leading)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.speaker)
                    .font(.system(size: scaled(12), weight: .semibold))
                    .foregroundStyle(speakerColor(entry.speaker))

                Text(entry.text)
                    .font(.system(size: scaled(14), weight: .regular))
                    .foregroundStyle(isLast ? .white : Theme.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(scaled(3))

                if let translated = entry.translatedText, shouldShowTranslation {
                    Text(translated)
                        .font(.system(size: scaled(14)))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .lineSpacing(scaled(2))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, scaled(12))
        .background(isLast && recorder.isRecording ? Theme.accent.opacity(0.04) : .clear)
        .overlay(alignment: .bottom) {
            if !isLast { Divider().background(Theme.border).padding(.leading, scaled(70)) }
        }
    }

    private func timeString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - Summary Panel

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
                Text("AI Summary")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                if summaryService.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 4)
                }

                Spacer()

                if !summaryService.streamingText.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summaryService.streamingText, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textMuted)
                    .help("Copy summary")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().background(Theme.border)

            if !summaryService.lastError.isEmpty {
                Text(summaryService.lastError)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.redBright)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }

            if summaryService.streamingText.isEmpty && !summaryService.isGenerating {
                Text("Summary will appear after recording completes.")
                    .font(.system(size: scaled(12)))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    Text(summaryService.streamingText)
                        .font(.system(size: scaled(13)))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .lineSpacing(scaled(4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .frame(maxHeight: 200)
            }
        }
        .background(Theme.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.15), lineWidth: 0.5))
    }

    // MARK: - Export Strip

    private var exportStrip: some View {
        HStack(spacing: 8) {
            if recorder.state == .completed, !recorder.exportedFilePath.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13))
                Text("Saved")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green.opacity(0.8))

                Text(recorder.exportedFilePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: recorder.exportedFilePath)
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                        .font(.system(size: 11, weight: .medium))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            } else {
                Spacer()
            }
        }
        .frame(height: 28)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                micMuteButton
                saveAudioButton
            }

            languagePicker

            translationControls

            Spacer()

            if recorder.state == .completed && !recorder.entries.isEmpty {
                summaryButton
            }

            if recorder.isRecording {
                stopButton
            } else {
                startButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            Theme.surface.opacity(0.8)
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) { Divider().background(Theme.borderLight) }
        }
    }

    private var summaryButton: some View {
        Button {
            generateSummary()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                Text(summaryService.isGenerating ? "Generating..." : "Summarize")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(summaryModelManager.isReady ? Theme.accentSoft : Theme.textMuted)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Theme.accent.opacity(summaryModelManager.isReady ? 0.15 : 0.05), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!summaryModelManager.isReady || summaryService.isGenerating)
        .help(summaryModelManager.isReady ? "Generate AI summary" : "Connect Ollama and select a model first")
        .accessibilityIdentifier("SummarizeButton")
    }

    private var startButton: some View {
        Button {
            requestStartRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "record.circle")
                    .font(.system(size: 14, weight: .semibold))
                Text("Start Recording")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(recorder.state == .transcribing)
        .opacity(recorder.state == .transcribing ? 0.4 : 1)
        .accessibilityIdentifier("RecordButton")
    }

    private var stopButton: some View {
        Button {
            recorder.stopRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10))
                Text("Stop Recording")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color(red: 0.75, green: 0.15, blue: 0.15), in: Capsule())
            .shadow(color: Color.red.opacity(0.3), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("StopButton")
    }

    @State private var languageModelMissing = false

    private var languagePicker: some View {
        Menu {
            ForEach(MeetingRecorder.supportedRecognitionLanguages, id: \.code) { lang in
                Button {
                    recorder.recognitionLanguage = lang.code
                    checkLanguageAvailability()
                } label: {
                    HStack {
                        Text(lang.name)
                        if recorder.recognitionLanguage == lang.code {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button("Download language models...") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                Text(currentLanguageName)
                    .font(.system(size: 10, weight: .medium))
                if languageModelMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.yellow)
                }
            }
            .foregroundStyle(languageModelMissing ? .yellow : Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.10), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(recorder.isRecording)
        .onAppear { checkLanguageAvailability() }
    }

    private var currentLanguageName: String {
        MeetingRecorder.supportedRecognitionLanguages
            .first { $0.code == recorder.recognitionLanguage }?.name ?? recorder.recognitionLanguage
    }

    private func checkLanguageAvailability() {
        let code = recorder.recognitionLanguage
        DispatchQueue.global(qos: .utility).async {
            let available: Bool
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: code)) {
                available = recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
            } else {
                available = false
            }
            DispatchQueue.main.async {
                languageModelMissing = !available
            }
        }
    }

    private var translationControls: some View {
        HStack(spacing: 8) {
            if translationService.isAvailable {
                Toggle(isOn: $translationService.isEnabled) {
                    Label("Translate", systemImage: "globe")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(translationService.isEnabled ? Theme.accentSoft : Theme.textMuted)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                if translationService.isEnabled {
                    Picker("", selection: $translationService.targetLanguageCode) {
                        ForEach(TranslationService.supportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .frame(width: 130)
                    .controlSize(.small)
                }
            }
        }
    }

    private var shouldShowTranslation: Bool {
        translationService.isEnabled &&
        (translationService.displayMode == .bilingual || translationService.displayMode == .translated)
    }

    // MARK: - OBS-Style Icon Buttons

    private var micMuteButton: some View {
        Button {
            recorder.micMuted.toggle()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: recorder.micMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(recorder.micMuted ? Theme.redBright : Theme.accentSoft)
                Text(recorder.micMuted ? "Muted" : "Mic")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(recorder.micMuted ? Theme.redBright.opacity(0.8) : Theme.textMuted)
            }
            .frame(width: 40, height: 34)
            .background(
                recorder.micMuted
                    ? Color.red.opacity(0.15)
                    : Theme.accent.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(recorder.micMuted ? Color.red.opacity(0.3) : Theme.accent.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var saveAudioButton: some View {
        Button {
            if !recorder.isRecording {
                recorder.saveAudio.toggle()
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: recorder.saveAudio ? "internaldrive.fill" : "internaldrive")
                    .font(.system(size: 13))
                    .foregroundStyle(recorder.saveAudio ? Theme.accentSoft : Theme.textMuted)
                Text("Save")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(recorder.saveAudio ? Theme.textMuted : Theme.textMuted.opacity(0.5))
            }
            .frame(width: 40, height: 34)
            .background(
                recorder.saveAudio
                    ? Theme.accent.opacity(0.12)
                    : Color.white.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(recorder.saveAudio ? Theme.accent.opacity(0.2) : Color.white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .opacity(recorder.isRecording ? 0.5 : 1.0)
    }

    // MARK: - Font Size Controls

    private var fontSizeControls: some View {
        HStack(spacing: 2) {
            Button { decreaseFontScale() } label: {
                Text("A")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(fontScale <= fontScaleMin)
            .help("Decrease font size (⌘-)")

            Text("\(Int(fontScale * 100))%")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 34)
                .onTapGesture { resetFontScale() }
                .help("Reset to default (⌘0)")

            Button { increaseFontScale() } label: {
                Text("A")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(fontScale >= fontScaleMax)
            .help("Increase font size (⌘+)")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.04), in: Capsule())
    }

    private var fontSizeControlsCompact: some View {
        HStack(spacing: 1) {
            Button { decreaseFontScale() } label: {
                Text("A")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(fontScale <= fontScaleMin)

            Button { increaseFontScale() } label: {
                Text("A")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(fontScale >= fontScaleMax)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(Color.white.opacity(0.10), in: Capsule())
    }

    // MARK: - Summary Generation

    private func generateSummary() {
        showSummary = true
        Task {
            await summaryService.generateSummary(
                from: recorder.entries,
                modelName: summaryModelManager.selectedModel
            )
            if !summaryService.streamingText.isEmpty, !recorder.exportedFilePath.isEmpty {
                saveSummaryToExport()
            }
        }
    }

    private func saveSummaryToExport() {
        let path = recorder.exportedFilePath
        guard !path.isEmpty, !summaryService.streamingText.isEmpty else { return }
        let summaryURL = URL(fileURLWithPath: path).appendingPathComponent("summary.md")
        try? summaryService.streamingText.write(to: summaryURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Translation

    private func translateCommittedEntries() {
        guard translationService.isEnabled, translationService.isAvailable else { return }
        let entries = recorder.entries
        guard !entries.isEmpty else { return }

        var indicesToTranslate: [Int] = []
        for i in 0..<entries.count {
            let e = entries[i]
            if e.isCommitted {
                // Needs translation if never translated or text changed since last translation
                let needsTranslation = e.translatedText == nil
                    || (e.translatedSourceText != nil && e.translatedSourceText != e.text)
                if needsTranslation {
                    indicesToTranslate.append(i)
                }
            }
        }

        // Also translate the latest active entry if it's long enough
        // to provide real-time feedback while speaking
        if let lastIdx = entries.indices.last,
           !entries[lastIdx].isCommitted,
           entries[lastIdx].translatedText == nil,
           entries[lastIdx].text.count > 60 {
            indicesToTranslate.append(lastIdx)
        }

        guard !indicesToTranslate.isEmpty else { return }

        Task {
            for idx in indicesToTranslate {
                guard idx < self.recorder.entries.count else { continue }
                let text = self.recorder.entries[idx].text

                // Build context: include up to 2 previous committed entries
                var contextLines: [String] = []
                for prev in max(0, idx - 2)..<idx {
                    if prev < self.recorder.entries.count {
                        contextLines.append(self.recorder.entries[prev].text)
                    }
                }

                let translated: String?
                if contextLines.isEmpty {
                    translated = await translationService.translate(text)
                } else {
                    let contextBlock = contextLines.joined(separator: " ")
                    translated = await translationService.translateWithContext(
                        text: text,
                        context: contextBlock
                    )
                }

                if let translated {
                    await MainActor.run {
                        if idx < self.recorder.entries.count {
                            self.recorder.entries[idx].translatedText = translated
                            self.recorder.entries[idx].translatedSourceText = text
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func speakerColor(_ speaker: String) -> Color {
        if speaker == "You" { return Theme.accent }
        if speaker == "Remote" { return .orange }
        if speaker.hasPrefix("Speaker "),
           let num = Int(speaker.dropFirst(8)),
           num >= 1, num <= Self.speakerPalette.count {
            return Self.speakerPalette[num - 1]
        }
        return Theme.textSecondary
    }

    private static let speakerPalette: [Color] = [
        .orange, .green, .purple, .pink, .cyan, .mint, .indigo, .brown
    ]
}

// MARK: - Pulse Animation

private struct PulseAnimation: ViewModifier {
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .opacity(pulse ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

// MARK: - Translation Task Modifier

#if compiler(>=6.0) && canImport(Translation)
import Translation

@available(macOS 15.0, *)
private struct TranslationTaskModifierImpl: ViewModifier {
    @ObservedObject var translationService: TranslationService
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(config) { session in
                translationService.setSession(session)
            }
            .onAppear { updateConfig() }
            .onChange(of: translationService.isEnabled) { updateConfig() }
            .onChange(of: translationService.configurationNeedsUpdate) {
                if translationService.configurationNeedsUpdate {
                    updateConfig()
                    translationService.configurationNeedsUpdate = false
                }
            }
    }

    private func updateConfig() {
        guard translationService.isEnabled, translationService.isAvailable else {
            config = nil
            return
        }
        config = translationService.makeConfiguration()
    }
}

private struct TranslationTaskModifier: ViewModifier {
    @ObservedObject var translationService: TranslationService

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.modifier(TranslationTaskModifierImpl(translationService: translationService))
        } else {
            content
        }
    }
}
#else
private struct TranslationTaskModifier: ViewModifier {
    @ObservedObject var translationService: TranslationService
    func body(content: Content) -> some View { content }
}
#endif
