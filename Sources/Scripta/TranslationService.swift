import Foundation
import ScriptaCore
#if compiler(>=6.0) && canImport(Translation)
import Translation
#endif

enum TranslationDisplayMode: String, CaseIterable {
    case original = "Original"
    case translated = "Translation"
    case bilingual = "Bilingual"
}

final class TranslationService: ObservableObject {
    @Published var isEnabled: Bool = false {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "Scripta.translationEnabled") }
    }
    @Published var displayMode: TranslationDisplayMode = .bilingual {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: "Scripta.translationDisplayMode") }
    }
    @Published var sourceLanguageCode: String = "en" {
        didSet {
            UserDefaults.standard.set(sourceLanguageCode, forKey: "Scripta.translationSource")
            configurationNeedsUpdate = true
        }
    }
    @Published var targetLanguageCode: String = "zh-Hans" {
        didSet {
            UserDefaults.standard.set(targetLanguageCode, forKey: "Scripta.translationTarget")
            configurationNeedsUpdate = true
        }
    }
    @Published private(set) var isAvailable: Bool = false
    @Published var configurationNeedsUpdate: Bool = false

    static let supportedLanguages: [(code: String, name: String)] = [
        ("en", "English"),
        ("zh-Hans", "Chinese (Simplified)"),
        ("zh-Hant", "Chinese (Traditional)"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
        ("pt-BR", "Portuguese (Brazil)"),
        ("it", "Italian"),
        ("ru", "Russian"),
        ("ar", "Arabic"),
    ]

    private var activeSession: Any?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "Scripta.translationEnabled")
        if let mode = UserDefaults.standard.string(forKey: "Scripta.translationDisplayMode"),
           let parsed = TranslationDisplayMode(rawValue: mode) {
            displayMode = parsed
        }
        if let src = UserDefaults.standard.string(forKey: "Scripta.translationSource"), !src.isEmpty {
            sourceLanguageCode = src
        }
        if let tgt = UserDefaults.standard.string(forKey: "Scripta.translationTarget"), !tgt.isEmpty {
            targetLanguageCode = tgt
        }
        checkAvailability()
    }

    private func checkAvailability() {
        #if compiler(>=6.0) && canImport(Translation)
        if #available(macOS 15.0, *) {
            isAvailable = true
            mplog("Translation: available (macOS 15+)")
        } else {
            isAvailable = false
        }
        #else
        isAvailable = false
        mplog("Translation: framework not available in current SDK")
        #endif

        if !isAvailable && isEnabled {
            isEnabled = false
        }
    }

    #if compiler(>=6.0) && canImport(Translation)
    @available(macOS 15.0, *)
    func makeConfiguration() -> TranslationSession.Configuration {
        let src = Locale.Language(identifier: sourceLanguageCode)
        let tgt = Locale.Language(identifier: targetLanguageCode)
        return TranslationSession.Configuration(source: src, target: tgt)
    }

    @available(macOS 15.0, *)
    func setSession(_ session: TranslationSession) {
        activeSession = session
        mplog("Translation: session ready (\(sourceLanguageCode) → \(targetLanguageCode))")
    }
    #endif

    func translate(_ text: String) async -> String? {
        guard isEnabled, isAvailable,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        #if compiler(>=6.0) && canImport(Translation)
        if #available(macOS 15.0, *) {
            guard let session = activeSession as? TranslationSession else {
                mplog("Translation: no active session")
                return nil
            }
            do {
                let response = try await session.translate(text)
                return response.targetText
            } catch {
                mplog("Translation error: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }

    /// Translate text with preceding context for better quality.
    /// Uses a delimiter to separate context from the target text, then extracts just
    /// the translated target portion.
    func translateWithContext(text: String, context: String) async -> String? {
        guard isEnabled, isAvailable,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        #if compiler(>=6.0) && canImport(Translation)
        if #available(macOS 15.0, *) {
            guard let session = activeSession as? TranslationSession else {
                return nil
            }
            do {
                // Use a separator that's unlikely to be in speech
                let separator = " ||| "
                let combined = context + separator + text
                let fullResponse = try await session.translate(combined)
                let fullTranslation = fullResponse.targetText

                // Try to split on the translated separator
                // The Translation API often preserves delimiters like |||
                for sep in [" ||| ", "|||", " | ", "| "] {
                    if let range = fullTranslation.range(of: sep, options: .backwards) {
                        let result = String(fullTranslation[range.upperBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !result.isEmpty { return result }
                    }
                }

                // Fallback: translate just the text directly
                let directResponse = try await session.translate(text)
                return directResponse.targetText
            } catch {
                mplog("Translation(context) error: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }
}
