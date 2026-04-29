import Foundation
import MeetingPilotCore
import MLXLLM
import MLXLMCommon

final class SummaryService: ObservableObject {
    @Published var streamingText: String = ""
    @Published var isGenerating: Bool = false
    @Published var lastError: String = ""

    private let maxTokens = 400

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
            let params = GenerateParameters(
                temperature: 0.4,
                topP: 0.9,
                repetitionPenalty: 1.2,
                repetitionContextSize: 64
            )

            try await container.perform { [weak self] (context: ModelContext) in
                guard let self else { return }

                let userInput = UserInput(prompt: prompt)
                let lmInput = try await context.processor.prepare(input: userInput)

                var tokenCount = 0
                var recentLines: [String] = []
                let outputRef = UnsafeMutablePointer<String>.allocate(capacity: 1)
                outputRef.initialize(to: "")
                defer { outputRef.deinitialize(count: 1); outputRef.deallocate() }

                _ = try MLXLMCommon.generate(
                    input: lmInput,
                    parameters: params,
                    context: context
                ) { tokens in
                    if tokens.count > tokenCount {
                        let newSlice = Array(tokens[tokenCount..<tokens.count])
                        tokenCount = tokens.count
                        let piece = context.tokenizer.decode(tokens: newSlice)
                        outputRef.pointee += piece

                        let snapshot = outputRef.pointee
                        if self.detectLoop(in: snapshot, recentLines: &recentLines) {
                            return .stop
                        }

                        let cleaned = self.cleanOutput(snapshot)
                        Task { @MainActor in
                            self.streamingText = cleaned
                        }
                    }
                    return tokenCount < self.maxTokens ? .more : .stop
                }
            }

            await MainActor.run {
                streamingText = cleanOutput(streamingText)
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
        if transcript.count > 3000 {
            truncated = String(transcript.suffix(3000))
        } else {
            truncated = transcript
        }

        return """
        <|system|>You summarize meetings. Be concise. Output ONLY the summary, nothing else.<|end|>
        <|user|>Summarize this meeting transcript.

        TRANSCRIPT:
        \(truncated)
        END TRANSCRIPT

        Write a short summary (3-5 bullet points) and list any action items. Format:

        SUMMARY:
        - point 1
        - point 2

        ACTION ITEMS:
        - task 1 (owner)
        - task 2 (owner)

        If no action items, write "None identified."<|end|>
        <|assistant|>
        """
    }

    /// Detect repetitive loop patterns in generated text
    private func detectLoop(in text: String, recentLines: inout [String]) -> Bool {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > recentLines.count else { return false }

        let newLines = Array(lines[recentLines.count...])
        recentLines = lines

        for line in newLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 10 else { continue }

            let occurrences = lines.filter {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
            }.count
            if occurrences >= 3 {
                mplog("Loop detected: '\(trimmed)' repeated \(occurrences) times, stopping.")
                return true
            }
        }
        return false
    }

    /// Remove trailing repeated lines and clean up formatting
    private func cleanOutput(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")

        // Remove trailing duplicate lines
        while lines.count > 2 {
            let last = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prev = lines[lines.count - 2].trimmingCharacters(in: .whitespacesAndNewlines)
            if last == prev && !last.isEmpty {
                lines.removeLast()
            } else {
                break
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
