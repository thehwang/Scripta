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

private struct TranslationJob: Equatable {
    let entryID: UUID
    let text: String
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
    @Published private(set) var isSessionReady: Bool = false
    @Published var configurationNeedsUpdate: Bool = false

    /// Called on the main actor when a queued translation completes.
    var onTranslated: ((UUID, String, String) -> Void)?

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

    private var queuedJobs: [TranslationJob] = []

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
    #endif

    @MainActor
    func clearSession() {
        isSessionReady = false
        queuedJobs = []
    }

    @MainActor
    func scheduleTranslation(entryID: UUID, text: String) {
        guard isEnabled, isAvailable else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 20 else { return }

        if let existing = queuedJobs.firstIndex(where: { $0.entryID == entryID }) {
            if queuedJobs[existing].text == trimmed { return }
            queuedJobs[existing] = TranslationJob(entryID: entryID, text: trimmed)
            mplog("Translation: re-queued (\(trimmed.count) chars)")
            return
        }

        queuedJobs.append(TranslationJob(entryID: entryID, text: trimmed))
        mplog("Translation: queued (\(trimmed.count) chars, queue=\(queuedJobs.count))")
    }

    @MainActor
    var hasPendingJobs: Bool { !queuedJobs.isEmpty }

    #if compiler(>=6.0) && canImport(Translation)
    @available(macOS 15.0, *)
    @MainActor
    func runQueuedTranslations(using session: TranslationSession) async {
        guard isEnabled else { return }

        let jobs = queuedJobs
        queuedJobs = []
        guard !jobs.isEmpty else { return }

        for job in jobs {
            do {
                mplog("Translation: start (\(job.text.count) chars)")
                let response = try await session.translate(job.text)
                let result = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !result.isEmpty else {
                    mplog("Translation: empty result")
                    continue
                }
                mplog("Translation: ok (→ \(result.prefix(40))…)")
                onTranslated?(job.entryID, job.text, result)
            } catch {
                mplog("Translation error: \(error.localizedDescription)")
            }
        }
    }

    @available(macOS 15.0, *)
    @MainActor
    func attachSession(_ session: TranslationSession) async {
        isSessionReady = true
        mplog("Translation: session ready (\(sourceLanguageCode) → \(targetLanguageCode))")
        do {
            try await session.prepareTranslation()
            mplog("Translation: languages prepared")
        } catch {
            mplog("Translation prepare error: \(error.localizedDescription)")
        }
    }
    #endif
}
