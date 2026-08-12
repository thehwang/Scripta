import SwiftUI
import ScriptaCore

struct DeepAskSheet: View {
    let question: String
    let transcript: String
    let modelName: String
    let isModelReady: Bool
    let onDismiss: () -> Void

    @StateObject private var summaryService = SummaryService()
    @State private var answer = ""
    @State private var errorMessage: String?

    private enum Theme {
        static let bg = Color(red: 0.071, green: 0.075, blue: 0.090)
        static let surface = Color(red: 0.118, green: 0.122, blue: 0.137)
        static let border = Color.white.opacity(0.10)
        static let accent = Color(red: 0.35, green: 0.60, blue: 1.0)
        static let textPrimary = Color(red: 0.94, green: 0.94, blue: 0.96)
        static let textSecondary = Color(red: 0.65, green: 0.67, blue: 0.72)
        static let textMuted = Color(red: 0.48, green: 0.50, blue: 0.55)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.border)
            content
            Divider().background(Theme.border)
            footer
        }
        .frame(minWidth: 420, minHeight: 320)
        .background(Theme.bg)
        .task { await runDeepAsk() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.accent)
            Text("深问")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("关闭") { onDismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("问题")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                    Text(question)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    Text("回答")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(.red.opacity(0.9))
                    } else if summaryService.isChatGenerating && answer.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.vertical, 8)
                    } else {
                        Text(displayedAnswer)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(16)
        }
    }

    private var footer: some View {
        HStack {
            if !isModelReady {
                Text("Ollama 模型未就绪")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Button("完成") { onDismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var displayedAnswer: String {
        if summaryService.isChatGenerating {
            return summaryService.chatStreamingText
        }
        return answer
    }

    private func runDeepAsk() async {
        guard isModelReady else {
            errorMessage = "请先配置并连接 Ollama 模型。"
            return
        }

        do {
            let result = try await summaryService.askQuestion(
                transcript: transcript,
                chatHistory: [],
                question: question,
                modelName: modelName
            )
            answer = result
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
