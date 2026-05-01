import Foundation
import MeetingPilotCore

struct SessionMetadata: Codable {
    let date: Date
    let duration: TimeInterval
    let entryCount: Int
    let language: String
    let hasSummary: Bool
    let hasAudio: Bool
}

struct MeetingSession: Identifiable {
    let id: String
    let folderURL: URL
    let date: Date
    let duration: TimeInterval
    let entryCount: Int
    let language: String
    let hasSummary: Bool
    let hasAudio: Bool

    var displayDate: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }

    var durationText: String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

final class MeetingStore: ObservableObject {
    @Published var sessions: [MeetingSession] = []

    private let baseDir: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        self.baseDir = docs.appendingPathComponent("MeetingPilotScripts", isDirectory: true)
    }

    func loadSessions() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            sessions = []
            return
        }

        let parsed: [MeetingSession] = contents.compactMap { folderURL in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }

            let transcriptURL = folderURL.appendingPathComponent("transcript.md")
            guard fm.fileExists(atPath: transcriptURL.path) else { return nil }

            let metaURL = folderURL.appendingPathComponent("session.json")
            if let metaData = try? Data(contentsOf: metaURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let meta = try? decoder.decode(SessionMetadata.self, from: metaData) {
                    return MeetingSession(
                        id: folderURL.lastPathComponent,
                        folderURL: folderURL,
                        date: meta.date,
                        duration: meta.duration,
                        entryCount: meta.entryCount,
                        language: meta.language,
                        hasSummary: meta.hasSummary,
                        hasAudio: meta.hasAudio
                    )
                }
            }

            let date = parseDateFromFolderName(folderURL.lastPathComponent) ?? Date()
            let summaryExists = fm.fileExists(atPath: folderURL.appendingPathComponent("summary.md").path)
            let audioExists = fm.fileExists(atPath: folderURL.appendingPathComponent("audio-mic.m4a").path)
                || fm.fileExists(atPath: folderURL.appendingPathComponent("audio-system.m4a").path)
            let entryCount = countTranscriptEntries(at: transcriptURL)

            return MeetingSession(
                id: folderURL.lastPathComponent,
                folderURL: folderURL,
                date: date,
                duration: 0,
                entryCount: entryCount,
                language: "en-US",
                hasSummary: summaryExists,
                hasAudio: audioExists
            )
        }

        sessions = parsed.sorted { $0.date > $1.date }
    }

    func loadTranscript(for session: MeetingSession) -> String {
        let url = session.folderURL.appendingPathComponent("transcript.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func loadSummary(for session: MeetingSession) -> String? {
        let url = session.folderURL.appendingPathComponent("summary.md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func deleteSession(_ session: MeetingSession) {
        try? FileManager.default.removeItem(at: session.folderURL)
        sessions.removeAll { $0.id == session.id }
    }

    func searchSessions(query: String) -> [MeetingSession] {
        guard !query.isEmpty else { return sessions }
        let lower = query.lowercased()
        return sessions.filter { session in
            if session.displayDate.lowercased().contains(lower) { return true }
            let transcript = loadTranscript(for: session)
            return transcript.lowercased().contains(lower)
        }
    }

    private func parseDateFromFolderName(_ name: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return fmt.date(from: name)
    }

    private func countTranscriptEntries(at url: URL) -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return content.components(separatedBy: "\n").filter { $0.hasPrefix("[") && $0.contains("]:") }.count
    }
}
