import MeetingPilotCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var recorder: MeetingRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controls
            statusPanel
            liveScriptPanel
            finalScriptPanel
            exportPanel
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(minWidth: 700, minHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Meeting Pilot")
                .font(.system(size: 24, weight: .semibold))
            Text("Dual-channel capture: your mic (You) + system audio (Remote).")
                .foregroundStyle(.secondary)
        }
    }

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
            .disabled(recorder.isRecording || recorder.state == .transcribing || recorder.state == .diarizing)

            Button {
                recorder.stopRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.bordered)
            .disabled(!recorder.isRecording)
        }
    }

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
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(entry.speaker)
                                    .font(.system(.caption, design: .monospaced, weight: .bold))
                                    .foregroundStyle(speakerColor(entry.speaker))
                                    .frame(minWidth: 72, alignment: .trailing)
                                Text(entry.text)
                                    .textSelection(.enabled)
                            }
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
            .frame(height: 180)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }

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
            Text(recorder.exportedFilePath.isEmpty ? "No file exported yet." : recorder.exportedFilePath)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(recorder.exportedFilePath.isEmpty ? .secondary : .primary)
        }
    }

    private var statusColor: Color {
        switch recorder.state {
        case .idle:
            return .gray
        case .recording:
            return .red
        case .transcribing:
            return .orange
        case .diarizing:
            return .purple
        case .completed:
            return .green
        case .failed:
            return .pink
        }
    }

    private func speakerColor(_ speaker: String) -> Color {
        switch speaker {
        case "You":
            return .blue
        case "Remote":
            return .orange
        case "Speaker 1":
            return .orange
        case "Speaker 2":
            return .green
        case "Speaker 3":
            return .purple
        case "Speaker 4":
            return .pink
        default:
            return .secondary
        }
    }
}
