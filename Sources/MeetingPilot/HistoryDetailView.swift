import SwiftUI
import MeetingPilotCore

struct HistoryDetailView: View {
    let session: MeetingSession
    @ObservedObject var store: MeetingStore
    let modelName: String
    let isModelReady: Bool
    var onBack: () -> Void
    var onDelete: () -> Void

    @State private var transcript = ""
    @State private var summary: String?
    @State private var showChat = false
    @State private var showDeleteConfirm = false
    @State private var isRegenerating = false
    @StateObject private var summaryService = SummaryService()

    private enum Theme {
        static let bg = Color(red: 0.071, green: 0.075, blue: 0.090)
        static let surface = Color(red: 0.118, green: 0.122, blue: 0.137)
        static let border = Color.white.opacity(0.10)
        static let accent = Color(red: 0.35, green: 0.60, blue: 1.0)
        static let accentSoft = Color(red: 0.72, green: 0.82, blue: 1.0)
        static let textPrimary = Color(red: 0.94, green: 0.94, blue: 0.96)
        static let textSecondary = Color(red: 0.65, green: 0.67, blue: 0.72)
        static let textMuted = Color(red: 0.48, green: 0.50, blue: 0.55)
        static let redBright = Color(red: 1.0, green: 0.706, blue: 0.671)
    }

    var body: some View {
        HSplitView {
            mainContent
            if showChat {
                ChatPanel(
                    transcriptText: transcript,
                    modelName: modelName,
                    isModelReady: isModelReady
                )
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)
            }
        }
        .onAppear {
            transcript = store.loadTranscript(for: session)
            summary = store.loadSummary(for: session)
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            actionBar
            Divider().background(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sessionInfoCard
                    transcriptCard
                    if let summary, !summary.isEmpty {
                        summaryCard(summary)
                    }
                    if summaryService.isGenerating || !summaryService.streamingText.isEmpty {
                        regeneratingSummaryCard
                    }
                }
                .padding(16)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                showChat.toggle()
            } label: {
                Label(showChat ? "Hide Chat" : "Ask AI", systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isModelReady || transcript.isEmpty)
            .help("Chat with AI about this meeting")

            Button {
                regenerateSummary()
            } label: {
                Label(
                    summaryService.isGenerating ? "Generating..." : "Re-generate Summary",
                    systemImage: "sparkles"
                )
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isModelReady || summaryService.isGenerating || transcript.isEmpty)

            Spacer()

            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.folderURL.path)
            } label: {
                Label("Finder", systemImage: "folder")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.redBright)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .alert("Delete this meeting?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { onDelete() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will permanently delete the transcript, summary, and audio files for this session.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var sessionInfoCard: some View {
        HStack(spacing: 16) {
            infoItem(icon: "calendar", label: "Date", value: session.displayDate)
            if session.duration > 0 {
                infoItem(icon: "clock", label: "Duration", value: session.durationText)
            }
            infoItem(icon: "text.bubble", label: "Entries", value: "\(session.entryCount)")
            infoItem(icon: "globe", label: "Language", value: session.language)
            Spacer()
        }
        .padding(12)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 0.5))
    }

    private func infoItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcript")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Copy transcript")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(Theme.border)

            Text(transcript)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(4)
                .padding(14)
        }
        .background(Theme.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 0.5))
    }

    private func summaryCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                Text("AI Summary")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Copy summary")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(Theme.border)

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(4)
                .padding(14)
        }
        .background(Theme.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.15), lineWidth: 0.5))
    }

    private var regeneratingSummaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                Text("AI Summary (regenerating)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if summaryService.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 4)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(Theme.border)

            Text(summaryService.streamingText)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(4)
                .padding(14)
        }
        .background(Theme.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.15), lineWidth: 0.5))
    }

    private func regenerateSummary() {
        let entries = parseTranscriptEntries(transcript)
        guard !entries.isEmpty else { return }
        Task {
            await summaryService.generateSummary(from: entries, modelName: modelName)
            if !summaryService.streamingText.isEmpty {
                let newSummary = summaryService.streamingText
                let summaryURL = session.folderURL.appendingPathComponent("summary.md")
                try? newSummary.write(to: summaryURL, atomically: true, encoding: .utf8)
                summary = newSummary
            }
        }
    }

    private func parseTranscriptEntries(_ text: String) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            guard line.hasPrefix("[") else { continue }
            guard let closeBracket = line.firstIndex(of: "]") else { continue }
            let afterBracket = line[line.index(after: closeBracket)...]
            guard afterBracket.hasPrefix(" ") else { continue }
            let rest = afterBracket.dropFirst()
            guard let colonIdx = rest.firstIndex(of: ":") else { continue }
            let speaker = String(rest[rest.startIndex..<colonIdx])
            let content = String(rest[rest.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            entries.append(TranscriptEntry(speaker: speaker, text: content))
        }
        return entries
    }
}
