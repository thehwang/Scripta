#if compiler(>=6.0) && canImport(FoundationModels)
import FoundationModels
import ScriptaCore

@available(macOS 26, *)
@Generable
struct MeetingSuggestionOutput {
    @Guide(description: "True only when a clarifying question would genuinely help the user")
    var hasSuggestion: Bool

    @Guide(description: "Suggested question in the same language as the meeting")
    var question: String

    @Guide(description: "One short sentence explaining why to ask this")
    var rationale: String

    @Guide(description: "low, medium, or high")
    var confidence: String
}

@available(macOS 26, *)
enum FoundationModelSuggestionEngine {
    static func availabilityStatus() -> (enabled: Bool, reason: String) {
        switch SystemLanguageModel.default.availability {
        case .available:
            return (true, "Apple Intelligence model available")
        case .unavailable(let reason):
            return (false, "Apple Intelligence unavailable: \(reason)")
        }
    }

    static var isAvailable: Bool {
        availabilityStatus().enabled
    }

    static func evaluate(context: String) async throws -> MeetingSuggestion? {
        let instructions = """
        You monitor live meeting transcripts. Suggest at most one clarifying question the listener \
        might want to ask right now. Prefer silence over weak or generic questions. \
        Only suggest when something important is unclear, unresolved, or worth confirming.
        """

        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
        Recent transcript (last few minutes):
        \(context)

        Should the user ask a clarifying question now?
        """

        let response = try await session.respond(
            to: prompt,
            generating: MeetingSuggestionOutput.self
        )

        let output = response.content
        let question = output.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.hasSuggestion, !question.isEmpty else { return nil }

        let rationale = output.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingSuggestion(question: question, rationale: rationale)
    }
}
#endif
