import Foundation

public struct TranscriptEntry: Identifiable {
    public let id: UUID
    public var speaker: String
    public var text: String
    public var translatedText: String?
    public var isCommitted: Bool
    /// The text that was used to produce translatedText, so we can detect staleness
    public var translatedSourceText: String?
    public let timestamp: Date

    public init(speaker: String, text: String, translatedText: String? = nil, isCommitted: Bool = false, timestamp: Date = Date()) {
        self.id = UUID()
        self.speaker = speaker
        self.text = text
        self.translatedText = translatedText
        self.isCommitted = isCommitted
        self.timestamp = timestamp
    }
}
