#if compiler(>=6.0) && canImport(FoundationModels)
import FoundationModels
import ScriptaCore

@available(macOS 26, *)
private struct MeetingSuggestionJSON: Decodable {
    let hasSuggestion: Bool
    let question: String
    let rationale: String
}

@available(macOS 26, *)
enum FoundationModelSuggestionEngine {
    /// Meeting transcripts are unverified user content; permissive guardrails allow analysis.
    private static let meetingModel = SystemLanguageModel(
        useCase: .general,
        guardrails: .permissiveContentTransformations
    )

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
        You analyze live meeting transcripts for a note-taking app. The transcript may discuss \
        news, business, or sensitive topics — analyze it professionally. Suggest at most one \
        clarifying question the listener might ask right now. Prefer no suggestion over a weak one.
        Reply with ONLY minified JSON using this schema:
        {"hasSuggestion":boolean,"question":string,"rationale":string}
        If hasSuggestion is false, set question and rationale to empty strings.
        """

        let session = LanguageModelSession(model: meetingModel, instructions: instructions)
        let prompt = """
        Recent transcript (last few minutes):
        \(context)
        """

        let response = try await session.respond(to: prompt)
        return parseSuggestion(from: response.content)
    }

    private static func parseSuggestion(from text: String) -> MeetingSuggestion? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var jsonText = trimmed
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            jsonText = String(trimmed[start...end])
        }

        guard let data = jsonText.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(MeetingSuggestionJSON.self, from: data) else {
            mplog("SuggestionEngine: could not parse response: \(trimmed.prefix(200))")
            return nil
        }

        let question = parsed.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard parsed.hasSuggestion, !question.isEmpty else { return nil }

        let rationale = parsed.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingSuggestion(question: question, rationale: rationale)
    }
}
#endif
