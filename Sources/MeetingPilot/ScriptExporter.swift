import Foundation
import MeetingPilotCore

enum ScriptExporter {
    static func exportScript(content: String) throws -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        let outputDir = docs.appendingPathComponent("MeetingPilotScripts", isDirectory: true)
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "\(formatter.string(from: Date()))_meeting-pilot.md"
        let url = outputDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func makeScriptFileContent(startedAt: Date?, endedAt: Date?, entries: [TranscriptEntry]) -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        let startText = startedAt.map { dateFmt.string(from: $0) } ?? "unknown"
        let endText = endedAt.map { dateFmt.string(from: $0) } ?? "unknown"

        var lines: [String] = [
            "Meeting Pilot Script",
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
}
