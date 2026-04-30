import Foundation
import MeetingPilotCore

final class SummaryService: ObservableObject {
    @Published var streamingText: String = ""
    @Published var isGenerating: Bool = false
    @Published var lastError: String = ""

    private let maxTokens = 512
    private static let baseURL = "http://localhost:11434"

    func generateSummary(from entries: [TranscriptEntry], modelName: String) async {
        let transcript = entries.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
        guard !transcript.isEmpty else {
            await MainActor.run { lastError = "No transcript to summarize." }
            return
        }

        guard !modelName.isEmpty else {
            await MainActor.run { lastError = "No AI model selected. Please select one in Settings." }
            return
        }

        await MainActor.run {
            streamingText = ""
            isGenerating = true
            lastError = ""
        }

        let prompt = buildPrompt(transcript: transcript)

        guard let url = URL(string: "\(Self.baseURL)/api/generate") else {
            await MainActor.run {
                isGenerating = false
                lastError = "Invalid Ollama URL"
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": modelName,
            "prompt": prompt,
            "stream": true,
            "options": [
                "temperature": 0.4,
                "top_p": 0.9,
                "repeat_penalty": 1.2,
                "num_predict": maxTokens,
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    isGenerating = false
                    lastError = "Ollama returned HTTP \(code). Is the model '\(modelName)' installed?"
                }
                return
            }

            var output = ""
            var recentLines: [String] = []

            for try await line in bytes.lines {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                if let piece = json["response"] as? String {
                    output += piece

                    if detectLoop(in: output, recentLines: &recentLines) {
                        mplog("Loop detected, stopping generation")
                        break
                    }

                    let cleaned = cleanOutput(output)
                    await MainActor.run {
                        streamingText = cleaned
                    }
                }

                if let done = json["done"] as? Bool, done {
                    break
                }

                if let errorMsg = json["error"] as? String {
                    await MainActor.run {
                        isGenerating = false
                        lastError = errorMsg
                    }
                    return
                }
            }

            let finalOutput = output
            await MainActor.run {
                streamingText = cleanOutput(finalOutput)
                isGenerating = false
            }
            mplog("Summary generation complete (\(finalOutput.count) chars)")
        } catch {
            await MainActor.run {
                isGenerating = false
                lastError = "Connection to Ollama failed: \(error.localizedDescription)"
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
        You summarize meetings. Be concise. Output ONLY the summary, nothing else.

        Summarize this meeting transcript.

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

        If no action items, write "None identified."
        """
    }

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

    private func cleanOutput(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")

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
