import Foundation

struct MeetingSuggestion: Equatable, Identifiable {
    let id = UUID()
    let question: String
    let rationale: String
}
