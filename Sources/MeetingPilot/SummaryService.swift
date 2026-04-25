import Foundation
import MeetingPilotCore
import MLXLLM
import MLXLMCommon

final class SummaryService: ObservableObject {
    @Published var streamingText: String = ""
    @Published var isGenerating: Bool = false
    @Published var lastError: String = ""

    private let maxTokens = 512

    func generateSummary(from entries: [TranscriptEntry], using modelManager: SummaryModelManager) async {
        guard let container = modelManager.container else {
            await MainActor.run { lastError = "No AI model loaded. Please download one in Settings." }
            return
        }

        let transcript = entries.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
        guard !transcript.isEmpty else {
            await MainActor.run { lastError = "No transcript to summarize." }
            return
        }

        await MainActor.run {
            streamingText = ""
            isGenerating = true
            lastError = ""
        }

        let prompt = buildPrompt(transcript: transcript)

        do {
            try await container.perform { [weak self] (context: ModelContext) in
                guard let self else { return }

                let userInput = UserInput(prompt: prompt)
                let lmInput = try await context.processor.prepare(input: userInput)

                var tokenCount = 0
                _ = try MLXLMCommon.generate(
                    input: lmInput,
                    parameters: GenerateParameters(temperature: 0.3),
                    context: context
                ) { tokens in
                    if tokens.count > tokenCount {
                        let newSlice = Array(tokens[tokenCount..<tokens.count])
                        tokenCount = tokens.count
                        let piece = context.tokenizer.decode(tokens: newSlice)
                        Task { @MainActor in
                            self.streamingText += piece
                        }
                    }
                    return tokenCount < self.maxTokens ? .more : .stop
                }
            }

            await MainActor.run {
                isGenerating = false
            }
            mplog("Summary generation complete (\(streamingText.count) chars)")
        } catch {
            await MainActor.run {
                isGenerating = false
                lastError = error.localizedDescription
            }
            mplog("Summary generation failed: \(error.localizedDescription)")
        }
    }

    private func buildPrompt(transcript: String) -> String {
        let truncated: String
        if transcript.count > 4000 {
            truncated = String(transcript.suffix(4000))
        } else {
            truncated = transcript
        }

        return """
        You are a meeting assistant. Analyze the following meeting transcript and produce a concise output with exactly two sections:

        ## Summary
        - 3-5 bullet points covering the key topics discussed

        ## Action Items
        - List specific tasks, decisions, or follow-ups mentioned
        - Include the responsible person if identifiable (e.g. "You" or "Remote")

        If no clear action items exist, write "No action items identified."

        Transcript:
        \(truncated)
        """
    }
}
