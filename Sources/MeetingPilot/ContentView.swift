import AVFoundation
import MeetingPilotCore
import Speech
import SwiftUI

// MARK: - Color Theme

private enum Theme {
    static let bg = Color(red: 0.071, green: 0.075, blue: 0.090)           // #121317
    static let surface = Color(red: 0.118, green: 0.122, blue: 0.137)      // #1e1f23
    static let surfaceHigh = Color(red: 0.161, green: 0.165, blue: 0.180)  // #292a2e
    static let border = Color.white.opacity(0.06)
    static let borderLight = Color.white.opacity(0.10)
    static let accent = Color(red: 0.294, green: 0.557, blue: 1.0)         // #4b8eff
    static let accentSoft = Color(red: 0.678, green: 0.776, blue: 1.0)     // #adc6ff
    static let textPrimary = Color(red: 0.890, green: 0.886, blue: 0.906)  // #e3e2e7
    static let textSecondary = Color(red: 0.545, green: 0.565, blue: 0.627)
    static let textMuted = Color(red: 0.373, green: 0.384, blue: 0.420)
    static let red = Color(red: 0.576, green: 0.0, blue: 0.039)            // #93000a
    static let redBright = Color(red: 1.0, green: 0.706, blue: 0.671)
}

// MARK: - Main View

struct ContentView: View {
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var translationService: TranslationService

    @State private var translatedEntryCount = 0
    @State private var hasMicPermission = false
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Divider().background(Theme.border)

                VStack(spacing: 0) {
                    if !hasMicPermission && recorder.state == .idle {
                        permissionBanner.padding(.horizontal, 20).padding(.top, 16)
                    }
                    statusStrip.padding(.horizontal, 20).padding(.top, 16)
                    transcriptPanel.padding(.horizontal, 20).padding(.top, 12)
                    exportStrip.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)
                }

                Spacer(minLength: 0)
                bottomBar
            }
        }
        .frame(minWidth: 760, minHeight: 600)
        .preferredColorScheme(.dark)
        .onChange(of: recorder.entries.count) { translateNewEntries() }
        .onAppear { refreshPermissionStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
        .onReceive(timer) { now = $0 }
    }

    private func refreshPermissionStatus() {
        hasMicPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 0) {
            Text("Meeting Pilot")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)

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

            enginePicker
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

    private var enginePicker: some View {
        Picker("", selection: $recorder.transcriptionEngine) {
            ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                Text(engine.rawValue).tag(engine)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
        .disabled(recorder.isRecording || recorder.state == .transcribing)
    }

    // MARK: - Status Strip (Duration + Info)

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
                    if let last = recorder.entries.last {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
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
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 50, alignment: .leading)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.speaker)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(speakerColor(entry.speaker))

                Text(entry.text)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(isLast ? .white : Theme.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(3)

                if let translated = entry.translatedText, shouldShowTranslation {
                    Text(translated)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .lineSpacing(2)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(isLast && recorder.isRecording ? Theme.accent.opacity(0.04) : .clear)
        .overlay(alignment: .bottom) {
            if !isLast { Divider().background(Theme.border).padding(.leading, 70) }
        }
    }

    private func timeString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
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
            HStack(spacing: 10) {
                Toggle(isOn: $recorder.saveAudio) {
                    Label("Audio", systemImage: recorder.saveAudio ? "waveform.circle.fill" : "waveform.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(recorder.saveAudio ? Theme.accentSoft : Theme.textMuted)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(recorder.isRecording)
            }

            translationControls

            Spacer()

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

    private var startButton: some View {
        Button {
            Task { @MainActor in await recorder.startRecording() }
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

    // MARK: - Translation

    private func translateNewEntries() {
        guard translationService.isEnabled, translationService.isAvailable else { return }
        let entries = recorder.entries
        let startIdx = translatedEntryCount
        guard startIdx < entries.count else { return }
        translatedEntryCount = entries.count

        Task {
            for i in startIdx..<entries.count {
                let text = entries[i].text
                if let translated = await translationService.translate(text) {
                    await MainActor.run {
                        if i < self.recorder.entries.count {
                            self.recorder.entries[i].translatedText = translated
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
