import AppKit
import SwiftUI

struct SuggestionStrip: View {
    let suggestion: MeetingSuggestion
    let onDeepAsk: () -> Void
    let onDismiss: () -> Void

    private enum Theme {
        static let surface = Color(red: 0.118, green: 0.122, blue: 0.137)
        static let accent = Color(red: 0.35, green: 0.60, blue: 1.0)
        static let textPrimary = Color(red: 0.94, green: 0.94, blue: 0.96)
        static let textSecondary = Color(red: 0.65, green: 0.67, blue: 0.72)
        static let textMuted = Color(red: 0.48, green: 0.50, blue: 0.55)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("建议提问")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)

                    Text(suggestion.question)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    if !suggestion.rationale.isEmpty {
                        Text(suggestion.rationale)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
            }

            HStack(spacing: 8) {
                actionButton("复制", systemImage: "doc.on.doc") {
                    copyToPasteboard(suggestion.question)
                }
                actionButton("深问", systemImage: "sparkles", accent: true, onDeepAsk)
                actionButton("忽略", systemImage: "xmark") { onDismiss() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surface.opacity(0.95))
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        accent: Bool = false,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(accent ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(accent ? 0.10 : 0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
