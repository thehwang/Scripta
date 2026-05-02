import SwiftUI

struct HistoryPanel: View {
    @ObservedObject var store: MeetingStore
    let modelName: String
    let isModelReady: Bool
    var onDismiss: () -> Void

    @State private var searchQuery = ""
    @State private var selectedSession: MeetingSession?

    private enum Theme {
        static let bg = Color(red: 0.071, green: 0.075, blue: 0.090)
        static let surface = Color(red: 0.118, green: 0.122, blue: 0.137)
        static let border = Color.white.opacity(0.10)
        static let accent = Color(red: 0.35, green: 0.60, blue: 1.0)
        static let textPrimary = Color(red: 0.94, green: 0.94, blue: 0.96)
        static let textSecondary = Color(red: 0.65, green: 0.67, blue: 0.72)
        static let textMuted = Color(red: 0.48, green: 0.50, blue: 0.55)
    }

    private var filteredSessions: [MeetingSession] {
        if searchQuery.isEmpty { return store.sessions }
        return store.searchSessions(query: searchQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.border)

            if let session = selectedSession {
                HistoryDetailView(
                    session: session,
                    store: store,
                    modelName: modelName,
                    isModelReady: isModelReady,
                    onBack: { selectedSession = nil },
                    onDelete: {
                        store.deleteSession(session)
                        selectedSession = nil
                    }
                )
            } else {
                sessionList
            }
        }
        .background(Theme.bg)
        .frame(minWidth: 500, minHeight: 400)
        .onAppear { store.loadSessions() }
    }

    private var header: some View {
        HStack {
            if selectedSession != nil {
                Button {
                    selectedSession = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }

            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
            Text(selectedSession == nil ? "Meeting History" : selectedSession!.displayDate)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                TextField("Search transcripts...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if filteredSessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.textMuted)
                    Text(searchQuery.isEmpty ? "No meeting recordings yet" : "No results for \"\(searchQuery)\"")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredSessions) { session in
                            sessionRow(session)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func sessionRow(_ session: MeetingSession) -> some View {
        Button {
            selectedSession = session
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayDate)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)

                    HStack(spacing: 10) {
                        if session.duration > 0 {
                            Label(session.durationText, systemImage: "clock")
                        }
                        Label("\(session.entryCount) entries", systemImage: "text.bubble")
                        if session.hasSummary {
                            Label("Summary", systemImage: "sparkles")
                        }
                        if session.hasAudio {
                            Label("Audio", systemImage: "waveform")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)

                    let preview = transcriptPreview(for: session)
                    if !preview.isEmpty {
                        Text(preview)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func transcriptPreview(for session: MeetingSession) -> String {
        let transcript = store.loadTranscript(for: session)
        let lines = transcript.components(separatedBy: "\n")
            .filter { $0.hasPrefix("[") && $0.contains("]:") }
        guard let first = lines.first else { return "" }
        if first.count > 80 { return String(first.prefix(80)) + "..." }
        return first
    }
}
