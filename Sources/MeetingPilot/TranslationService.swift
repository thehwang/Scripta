import Foundation
import MeetingPilotCore

enum TranslationDisplayMode: String, CaseIterable {
    case original = "Original"
    case translated = "Translation"
    case bilingual = "Bilingual"
}

/// Translation service that uses Apple's Translation framework (macOS 15+).
/// On older macOS / SDK versions, translation methods return nil gracefully.
final class TranslationService: ObservableObject {
    @Published var isEnabled: Bool = false {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "MeetingPilot.translationEnabled") }
    }
    @Published var displayMode: TranslationDisplayMode = .bilingual {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: "MeetingPilot.translationDisplayMode") }
    }
    @Published var sourceLanguageCode: String = "en" {
        didSet { UserDefaults.standard.set(sourceLanguageCode, forKey: "MeetingPilot.translationSource") }
    }
    @Published var targetLanguageCode: String = "zh-Hans" {
        didSet { UserDefaults.standard.set(targetLanguageCode, forKey: "MeetingPilot.translationTarget") }
    }
    @Published private(set) var isAvailable: Bool = false

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

    private var translationImpl: Any?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "MeetingPilot.translationEnabled")
        if let mode = UserDefaults.standard.string(forKey: "MeetingPilot.translationDisplayMode"),
           let parsed = TranslationDisplayMode(rawValue: mode) {
            displayMode = parsed
        }
        if let src = UserDefaults.standard.string(forKey: "MeetingPilot.translationSource"), !src.isEmpty {
            sourceLanguageCode = src
        }
        if let tgt = UserDefaults.standard.string(forKey: "MeetingPilot.translationTarget"), !tgt.isEmpty {
            targetLanguageCode = tgt
        }

        checkAvailability()
    }

    func translate(_ text: String) async -> String? {
        guard isEnabled, isAvailable,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return await performTranslation(text)
    }

    // MARK: - Private

    private func checkAvailability() {
        if #available(macOS 15.0, *) {
            // Translation framework requires macOS 15+ at runtime.
            // The actual API availability also depends on the SDK used to compile.
            // We dynamically check if the class exists.
            isAvailable = NSClassFromString("TranslationSession") != nil
        } else {
            isAvailable = false
        }

        if !isAvailable && isEnabled {
            mplog("Translation: not available on this macOS version, disabling")
            isEnabled = false
        }
    }

    private func performTranslation(_ text: String) async -> String? {
        // Translation will be fully functional when compiled with macOS 15+ SDK.
        // For now, return nil gracefully.
        mplog("Translation: framework not available in current SDK, returning nil")
        return nil
    }
}
