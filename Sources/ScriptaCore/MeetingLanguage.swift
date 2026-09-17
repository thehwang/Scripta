import Foundation

public enum MeetingLanguage {
    public static let recognitionLanguages: [(code: String, name: String)] = [
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("zh-Hans", "中文 (简体)"),
        ("zh-Hant", "中文 (繁體)"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
        ("fr-FR", "Français"),
        ("de-DE", "Deutsch"),
        ("es-ES", "Español"),
        ("pt-BR", "Português"),
        ("it-IT", "Italiano"),
        ("ru-RU", "Русский"),
    ]

    public static func displayName(for recognitionLanguage: String) -> String {
        recognitionLanguages.first { $0.code == recognitionLanguage }?.name ?? recognitionLanguage
    }

    public static func whisperCode(from recognitionLanguage: String) -> String {
        recognitionLanguage.components(separatedBy: "-").first?.lowercased() ?? "en"
    }

    public static func translationSourceCode(from recognitionLanguage: String) -> String {
        switch recognitionLanguage {
        case "zh-Hans":
            return "zh-Hans"
        case "zh-Hant":
            return "zh-Hant"
        case "pt-BR":
            return "pt-BR"
        default:
            return whisperCode(from: recognitionLanguage)
        }
    }

    /// English name used in LLM prompts, e.g. "Respond in German."
    public static func outputLanguageName(for recognitionLanguage: String) -> String {
        switch recognitionLanguage {
        case "en-US", "en-GB":
            return "English"
        case "zh-Hans":
            return "Chinese (Simplified)"
        case "zh-Hant":
            return "Chinese (Traditional)"
        case "ja-JP":
            return "Japanese"
        case "ko-KR":
            return "Korean"
        case "fr-FR":
            return "French"
        case "de-DE":
            return "German"
        case "es-ES":
            return "Spanish"
        case "pt-BR":
            return "Portuguese (Brazil)"
        case "it-IT":
            return "Italian"
        case "ru-RU":
            return "Russian"
        default:
            return displayName(for: recognitionLanguage)
        }
    }

    public static func outputLanguageInstruction(for recognitionLanguage: String) -> String {
        "Respond in \(outputLanguageName(for: recognitionLanguage))."
    }

    public static func isEnglish(_ recognitionLanguage: String) -> Bool {
        whisperCode(from: recognitionLanguage) == "en"
    }
}
