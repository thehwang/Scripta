import Foundation
import MeetingPilotCore
import MLXLLM
import MLXLMCommon

enum LLMModelDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case loading
    case ready
    case failed(message: String)
}

struct LLMModelInfo: Identifiable {
    let id: String
    let name: String
    let sizeDescription: String
    let description: String
    let isDefault: Bool
    let overrideTokenizer: String?
    let extraEOSTokens: Set<String>

    var modelConfiguration: ModelConfiguration {
        ModelConfiguration(
            id: id,
            overrideTokenizer: overrideTokenizer,
            extraEOSTokens: extraEOSTokens
        )
    }
}

final class SummaryModelManager: ObservableObject {
    @Published var downloadState: LLMModelDownloadState = .notDownloaded
    @Published var selectedModelId: String {
        didSet { UserDefaults.standard.set(selectedModelId, forKey: Self.modelKey) }
    }

    private(set) var container: ModelContainer?

    static let availableModels: [LLMModelInfo] = [
        LLMModelInfo(
1            id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            name: "Qwen 2.5 1.5B (Recommended)",
            sizeDescription: "~1 GB",
            description: "Best balance of speed and quality for summaries",
            isDefault: true,
            overrideTokenizer: nil,
            extraEOSTokens: ["<|im_end|>"]
        ),
        LLMModelInfo(
            id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            name: "Qwen 2.5 0.5B",
            sizeDescription: "~400 MB",
            description: "Smallest & fastest, good for short meetings",
            isDefault: false,
            overrideTokenizer: nil,
            extraEOSTokens: ["<|im_end|>"]
        ),
        LLMModelInfo(
            id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            name: "Qwen 2.5 3B",
            sizeDescription: "~2 GB",
            description: "Higher quality, needs more memory",
            isDefault: false,
            overrideTokenizer: nil,
            extraEOSTokens: ["<|im_end|>"]
        ),
        LLMModelInfo(
            id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            name: "Llama 3.2 1B",
            sizeDescription: "~700 MB",
            description: "Strong English performance",
            isDefault: false,
            overrideTokenizer: nil,
            extraEOSTokens: []
        ),
        LLMModelInfo(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            name: "Llama 3.2 3B",
            sizeDescription: "~2 GB",
            description: "High quality English, needs more memory",
            isDefault: false,
            overrideTokenizer: nil,
            extraEOSTokens: []
        ),
        LLMModelInfo(
            id: "mlx-community/Phi-3.5-mini-instruct-4bit",
            name: "Phi 3.5 Mini",
            sizeDescription: "~2.3 GB",
            description: "Microsoft model, strong reasoning",
            isDefault: false,
            overrideTokenizer: nil,
            extraEOSTokens: ["<|end|>"]
        ),
    ]

    private static let modelKey = "MeetingPilot.summaryModel"

    var isReady: Bool { downloadState == .ready && container != nil }

    init() {
        let defaultId = Self.availableModels.first(where: \.isDefault)?.id ?? Self.availableModels[0].id
        self.selectedModelId = UserDefaults.standard.string(forKey: Self.modelKey) ?? defaultId
    }

    var selectedModelInfo: LLMModelInfo? {
        Self.availableModels.first { $0.id == selectedModelId }
    }

    func loadSelectedModel() async {
        guard let modelInfo = selectedModelInfo else {
            await MainActor.run {
                downloadState = .failed(message: "Unknown model selected.")
            }
            return
        }

        await MainActor.run { downloadState = .downloading(progress: 0) }

        let configuration = modelInfo.modelConfiguration
        mplog("Loading LLM model: \(modelInfo.id) overrideTokenizer=\(modelInfo.overrideTokenizer ?? "nil")")

        do {
            let loaded = try await LLMModelFactory.shared.loadContainer(
                configuration: configuration
            ) { progress in
                Task { @MainActor in
                    self.downloadState = .downloading(progress: progress.fractionCompleted)
                }
            }

            await MainActor.run {
                self.container = loaded
                self.downloadState = .ready
            }
            mplog("LLM model loaded: \(modelInfo.id)")
        } catch {
            await MainActor.run {
                self.downloadState = .failed(message: error.localizedDescription)
            }
            mplog("LLM model load failed: \(error.localizedDescription)")
        }
    }

    func unloadModel() {
        container = nil
        downloadState = .notDownloaded
    }
}
