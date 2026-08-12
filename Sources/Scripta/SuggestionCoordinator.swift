import Foundation
import ScriptaCore

@MainActor
final class SuggestionCoordinator: ObservableObject {
    @Published private(set) var currentSuggestion: MeetingSuggestion?
    @Published private(set) var isEvaluating = false

    private var buffer = RollingContextBuffer(windowSeconds: 180)
    private var lastProcessedCommittedCount = 0
    private var lastEvaluationTime: Date?
    private var recentQuestions: [String] = []
    private var evaluationTask: Task<Void, Never>?

    private let cooldownSeconds: TimeInterval = 25
    private let minCharacters = 100
    private let minTurns = 2
    private let recentQuestionLimit = 8

    var isEnabled: Bool {
        Self.availabilityStatus().enabled
    }

    static func availabilityStatus() -> (enabled: Bool, reason: String) {
        #if compiler(>=6.0) && canImport(FoundationModels)
        if #available(macOS 26, *) {
            return FoundationModelSuggestionEngine.availabilityStatus()
        }
        return (false, "requires macOS 26")
        #else
        return (false, "Foundation Models not compiled — build with Xcode 26+ (Swift 6 SDK)")
        #endif
    }

    func logAvailabilityIfNeeded() {
        let status = Self.availabilityStatus()
        mplog("Suggestions: \(status.enabled ? "enabled" : "disabled") — \(status.reason)")
    }

    func reset() {
        evaluationTask?.cancel()
        evaluationTask = nil
        buffer = RollingContextBuffer(windowSeconds: 180)
        lastProcessedCommittedCount = 0
        lastEvaluationTime = nil
        recentQuestions.removeAll()
        currentSuggestion = nil
        isEvaluating = false
    }

    func dismissCurrent() {
        if let question = currentSuggestion?.question {
            rememberQuestion(question)
        }
        currentSuggestion = nil
    }

    func processEntries(_ entries: [TranscriptEntry], isRecording: Bool) {
        guard isEnabled, isRecording else {
            if !isRecording { reset() }
            return
        }

        buffer.ingest(entries: entries)

        let committedCount = entries.filter(\.isCommitted).count
        guard committedCount > lastProcessedCommittedCount else { return }
        lastProcessedCommittedCount = committedCount

        guard shouldEvaluate() else { return }
        scheduleEvaluation()
    }

    private func shouldEvaluate() -> Bool {
        guard !isEvaluating else { return false }
        guard buffer.characterCount >= minCharacters || buffer.turnCount >= minTurns else {
            return false
        }

        if let lastEvaluationTime,
           Date().timeIntervalSince(lastEvaluationTime) < cooldownSeconds {
            return false
        }

        return true
    }

    private func scheduleEvaluation() {
        evaluationTask?.cancel()
        evaluationTask = Task { [weak self] in
            await self?.evaluateCurrentBuffer()
        }
    }

    private func evaluateCurrentBuffer() async {
        let context = buffer.contextText
        guard !context.isEmpty else { return }

        isEvaluating = true
        lastEvaluationTime = Date()
        defer { isEvaluating = false }

        #if compiler(>=6.0) && canImport(FoundationModels)
        if #available(macOS 26, *) {
            do {
                guard let suggestion = try await FoundationModelSuggestionEngine.evaluate(context: context) else {
                    return
                }
                guard !Task.isCancelled else { return }
                guard !isDuplicate(suggestion.question) else { return }
                currentSuggestion = suggestion
            } catch {
                if String(describing: error).contains("unsafe") {
                    mplog("SuggestionEngine: guardrail blocked transcript content")
                } else {
                    mplog("SuggestionEngine: \(error.localizedDescription)")
                }
            }
        }
        #endif
    }

    private func isDuplicate(_ question: String) -> Bool {
        let normalized = normalize(question)
        return recentQuestions.contains(normalized)
    }

    private func rememberQuestion(_ question: String) {
        let normalized = normalize(question)
        recentQuestions.append(normalized)
        if recentQuestions.count > recentQuestionLimit {
            recentQuestions.removeFirst(recentQuestions.count - recentQuestionLimit)
        }
    }

    private func normalize(_ question: String) -> String {
        question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
