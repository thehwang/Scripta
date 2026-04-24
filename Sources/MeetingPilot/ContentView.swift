import AVFoundation
import MeetingPilotCore
import Speech
import SwiftUI

struct ContentView: View {
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var translationService: TranslationService

    @State private var translatedEntryCount = 0
    @State private var hasMicPermission = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !hasMicPermission {
                permissionPanel
            }
            controls
            statusPanel
            liveScriptPanel
            finalScriptPanel
            exportPanel
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(minWidth: 700, minHeight: 620)
        .onChange(of: recorder.entries.count) {
            translateNewEntries()
        }
        .onAppear { refreshPermissionStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
    }

    private func refreshPermissionStatus() {
        hasMicPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Meeting Pilot")
                    .font(.system(size: 24, weight: .semibold))
                Spacer()
                engineBadge
            }
            Text("Dual-channel capture: your mic (You) + system audio (Remote).")
                .foregroundStyle(.secondary)
        }
    }

    private var engineBadge: some View {
        Picker("Engine", selection: $recorder.transcriptionEngine) {
            ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                Text(engine.rawValue).tag(engine)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 200)
        .disabled(recorder.isRecording || recorder.state == .transcribing)
    }

    // MARK: - Permission Panel

    private var permissionPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Microphone Permission Needed", systemImage: "exclamationmark.shield")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)

            HStack(spacing: 6) {
                Image(systemName: "mic.slash")
                    .foregroundStyle(.red)
                Text("Microphone access has not been granted.")
                    .font(.footnote)
                Spacer()
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }

            Text("Add MeetingPilot in System Settings → Privacy & Security → Microphone, then return here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                Task { @MainActor in
                    await recorder.startRecording()
                }
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .disabled(recorder.isRecording || recorder.state == .transcribing)

            Button {
                recorder.stopRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.bordered)
            .disabled(!recorder.isRecording)

            Toggle("Save Audio", isOn: $recorder.saveAudio)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(recorder.isRecording)

            Spacer()

            translationControls
        }
    }

    private var translationControls: some View {
        HStack(spacing: 8) {
            if translationService.isAvailable {
                Toggle("Translate", isOn: $translationService.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                if translationService.isEnabled {
                    Picker("", selection: $translationService.targetLanguageCode) {
                        ForEach(TranslationService.supportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .frame(width: 140)
                    .controlSize(.small)

                    Picker("", selection: $translationService.displayMode) {
                        ForEach(TranslationDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .frame(width: 100)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Status

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Status:")
                    .fontWeight(.medium)
                Text(recorder.state.rawValue)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.2), in: Capsule())
                Text(recorder.statusMessage)
                    .foregroundStyle(.secondary)
            }

            if !recorder.lastError.isEmpty {
                Text(recorder.lastError)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
    }

    // MARK: - Live Script

    private var liveScriptPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Real-time Script")
                .font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if recorder.entries.isEmpty {
                            Text("Live transcript will appear here...")
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                        ForEach(recorder.entries) { entry in
                            entryRow(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: recorder.entries.count) {
                    if let last = recorder.entries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .frame(height: 200)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func entryRow(_ entry: TranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.speaker)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(speakerColor(entry.speaker))
                    .frame(minWidth: 72, alignment: .trailing)
                Text(entry.text)
                    .textSelection(.enabled)
            }

            if let translated = entry.translatedText, shouldShowTranslation {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Color.clear.frame(width: 72)
                    Text(translated)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var shouldShowTranslation: Bool {
        translationService.isEnabled &&
        (translationService.displayMode == .bilingual || translationService.displayMode == .translated)
    }

    // MARK: - Final Script & Export

    private var finalScriptPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Final Script")
                .font(.headline)
            ScrollView {
                Text(recorder.finalScript.isEmpty ? "Final script will appear after recording stops." : recorder.finalScript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: 120)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Export")
                .font(.headline)
            if recorder.exportedFilePath.isEmpty {
                Text("No file exported yet.")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text(recorder.exportedFilePath)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer()
                    Button("Open in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: recorder.exportedFilePath)
                    }
                    .controlSize(.small)
                }
            }
        }
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

    private var statusColor: Color {
        switch recorder.state {
        case .idle: return .gray
        case .recording: return .red
        case .transcribing: return .orange
        case .completed: return .green
        case .failed: return .pink
        }
    }

    private static let speakerPalette: [Color] = [
        .orange, .green, .purple, .pink, .cyan, .mint, .indigo, .brown
    ]

    private func speakerColor(_ speaker: String) -> Color {
        if speaker == "You" { return .blue }
        if speaker == "Remote" { return .orange }
        if speaker.hasPrefix("Speaker "),
           let num = Int(speaker.dropFirst(8)),
           num >= 1, num <= Self.speakerPalette.count {
            return Self.speakerPalette[num - 1]
        }
        return .secondary
    }
}
