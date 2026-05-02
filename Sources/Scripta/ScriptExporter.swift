import Foundation
import ScriptaCore

enum ScriptExporter {

    /// Per-session export: creates a timestamped folder containing transcript
    /// and optionally copies audio files into it.
    static func exportSession(
        content: String,
        translatedContent: String? = nil,
        micAudioURL: URL?,
        systemAudioURL: URL?,
        startedAt: Date?,
        entryCount: Int = 0,
        language: String = "en-US"
    ) throws -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        let baseDir = docs.appendingPathComponent("ScriptaScripts", isDirectory: true)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folderName = formatter.string(from: startedAt ?? Date())
        let sessionDir = baseDir.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let transcriptURL = sessionDir.appendingPathComponent("transcript.md")
        try content.write(to: transcriptURL, atomically: true, encoding: .utf8)

        if let translatedContent {
            let translatedURL = sessionDir.appendingPathComponent("transcript-bilingual.md")
            try translatedContent.write(to: translatedURL, atomically: true, encoding: .utf8)
        }

        let hasAudio: Bool
        if let src = micAudioURL, fm.fileExists(atPath: src.path) {
            let dst = sessionDir.appendingPathComponent("audio-mic.m4a")
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: src, to: dst)
            hasAudio = true
        } else if let src = systemAudioURL, fm.fileExists(atPath: src.path) {
            hasAudio = true
            let dst = sessionDir.appendingPathComponent("audio-system.m4a")
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: src, to: dst)
        } else {
            hasAudio = false
        }

        if let src = systemAudioURL, fm.fileExists(atPath: src.path),
           !fm.fileExists(atPath: sessionDir.appendingPathComponent("audio-system.m4a").path) {
            let dst = sessionDir.appendingPathComponent("audio-system.m4a")
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: src, to: dst)
        }

        let duration: TimeInterval
        if let start = startedAt {
            duration = Date().timeIntervalSince(start)
        } else {
            duration = 0
        }

        let metadata = SessionMetadata(
            date: startedAt ?? Date(),
            duration: duration,
            entryCount: entryCount,
            language: language,
            hasSummary: false,
            hasAudio: hasAudio
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let jsonData = try? encoder.encode(metadata) {
            let metaURL = sessionDir.appendingPathComponent("session.json")
            try? jsonData.write(to: metaURL)
        }

        return sessionDir
    }

    static func makeScriptFileContent(startedAt: Date?, endedAt: Date?, entries: [TranscriptEntry]) -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        let startText = startedAt.map { dateFmt.string(from: $0) } ?? "unknown"
        let endText = endedAt.map { dateFmt.string(from: $0) } ?? "unknown"

        var lines: [String] = [
            "Scripta Script",
            "====================",
            "Start: \(startText)",
            "End: \(endText)",
            "",
            "Transcript",
            "----------",
        ]

        if entries.isEmpty {
            lines.append("[No transcript captured]")
        } else {
            for entry in entries {
                let ts = timeFmt.string(from: entry.timestamp)
                lines.append("[\(ts)] \(entry.speaker): \(entry.text)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Generate a bilingual transcript with translations inline.
    static func makeTranslatedContent(startedAt: Date?, endedAt: Date?, entries: [TranscriptEntry]) -> String? {
        let hasTranslations = entries.contains { $0.translatedText != nil }
        guard hasTranslations else { return nil }

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        let startText = startedAt.map { dateFmt.string(from: $0) } ?? "unknown"
        let endText = endedAt.map { dateFmt.string(from: $0) } ?? "unknown"

        var lines: [String] = [
            "Scripta — Bilingual Transcript",
            "=====================================",
            "Start: \(startText)",
            "End: \(endText)",
            "",
        ]

        for entry in entries {
            let ts = timeFmt.string(from: entry.timestamp)
            lines.append("[\(ts)] \(entry.speaker): \(entry.text)")
            if let translated = entry.translatedText {
                lines.append("    → \(translated)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
