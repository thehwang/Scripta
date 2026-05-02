import SwiftUI
import MeetingPilotCore

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    var text: String
    let timestamp: Date

    var isUser: Bool { role == "user" }
}

struct ChatPanel: View {
    let transcriptText: String
    let modelName: String
    let isModelReady: Bool

    @StateObject private var summaryService = SummaryService()
    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""

    private var isGenerating: Bool { summaryService.isChatGenerating }
    private var streamingResponse: String { summaryService.chatStreamingText }

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
            messagesArea
            Divider().background(Theme.border)
            inputBar
        }
        .background(Theme.bg)
    }

    private var header: some View {
        HStack {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
            Text("Ask AI")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if !messages.isEmpty {
                Button {
                    messages.removeAll()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Clear chat")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty && !isGenerating {
                        emptyState
                    }
                    ForEach(messages) { msg in
                        messageBubble(msg)
                            .id(msg.id)
                    }
                    if isGenerating && !streamingResponse.isEmpty {
                        streamingBubble
                            .id("streaming")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: summaryService.chatStreamingText) {
                if isGenerating {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 24))
                .foregroundStyle(Theme.textMuted)
            if !transcriptText.isEmpty {
                Text("Ask questions about the meeting")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                Text("e.g. \"What decisions were made?\"")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted.opacity(0.7))
            } else {
                Text("Ask AI anything")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                Text("Record a meeting for transcript-based Q&A")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func messageBubble(_ msg: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if msg.isUser {
                Spacer(minLength: 40)
                Text(msg.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 4)
                Text(msg.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
                Spacer(minLength: 20)
            }
        }
    }

    private var streamingBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
                .padding(.top, 4)
            Text(streamingResponse)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 20)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(transcriptText.isEmpty ? "Ask AI anything..." : "Ask about this meeting...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .onSubmit { sendMessage() }
                .disabled(isGenerating || !isModelReady)

            Button {
                sendMessage()
            } label: {
                Image(systemName: isGenerating ? "stop.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canSend ? Theme.accent : Theme.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !isGenerating)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isGenerating
            && isModelReady
    }

    private func sendMessage() {
        let question = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        messages.append(ChatMessage(role: "user", text: question, timestamp: Date()))
        inputText = ""

        let history = messages.dropLast().map { (role: $0.role, text: $0.text) }
        let transcript = transcriptText
        let model = modelName

        Task {
            do {
                let result = try await summaryService.askQuestion(
                    transcript: transcript,
                    chatHistory: history,
                    question: question,
                    modelName: model
                )
                await MainActor.run {
                    messages.append(ChatMessage(role: "assistant", text: result, timestamp: Date()))
                }
            } catch {
                await MainActor.run {
                    messages.append(ChatMessage(
                        role: "assistant",
                        text: "Error: \(error.localizedDescription)",
                        timestamp: Date()
                    ))
                }
            }
        }
    }
}
