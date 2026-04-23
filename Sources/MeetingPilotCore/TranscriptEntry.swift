import Foundation

public struct TranscriptEntry: Identifiable {
    public let id: UUID
    public var speaker: String
    public var text: String
    public let timestamp: Date

    public init(speaker: String, text: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
    }
}
