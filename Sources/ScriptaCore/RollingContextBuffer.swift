import Foundation

/// Keeps committed transcript lines within a rolling time window.
public struct RollingContextBuffer {
    public let windowSeconds: TimeInterval

    private var lines: [(timestamp: Date, line: String)] = []

    public init(windowSeconds: TimeInterval = 180) {
        self.windowSeconds = windowSeconds
    }

    public mutating func ingest(entries: [TranscriptEntry], now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        lines = entries
            .filter { $0.isCommitted && $0.timestamp >= cutoff }
            .map { (timestamp: $0.timestamp, line: "[\($0.speaker)] \($0.text)") }
    }

    public var contextText: String {
        lines.map(\.line).joined(separator: "\n")
    }

    public var turnCount: Int { lines.count }

    public var characterCount: Int { contextText.count }
}
