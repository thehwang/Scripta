import Foundation
import MeetingPilotCore
import WhisperKit

enum ModelDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case ready(path: String)
    case failed(message: String)
}

struct WhisperModelInfo: Identifiable {
    let id: String
    let name: String
    let sizeDescription: String
    let accuracyDescription: String
    let isRecommended: Bool
}

final class ModelManager: ObservableObject {
    @Published var downloadState: ModelDownloadState = .notDownloaded
    @Published var selectedModelName: String {
        didSet { UserDefaults.standard.set(selectedModelName, forKey: Self.modelKey) }
    }

    static let availableModels: [WhisperModelInfo] = [
        WhisperModelInfo(id: "tiny", name: "Tiny", sizeDescription: "~40 MB",
                         accuracyDescription: "~85% accuracy, fastest", isRecommended: false),
        WhisperModelInfo(id: "base", name: "Base", sizeDescription: "~75 MB",
                         accuracyDescription: "~88% accuracy", isRecommended: false),
        WhisperModelInfo(id: "small", name: "Small", sizeDescription: "~250 MB",
                         accuracyDescription: "~92% accuracy, balanced", isRecommended: true),
        WhisperModelInfo(id: "medium", name: "Medium", sizeDescription: "~800 MB",
                         accuracyDescription: "~95% accuracy, slower", isRecommended: false),
        WhisperModelInfo(id: "large-v3", name: "Large v3", sizeDescription: "~1.6 GB",
                         accuracyDescription: "~97% accuracy, needs M1 Pro+", isRecommended: false),
    ]

    private static let modelKey = "MeetingPilot.selectedModel"
    private static let appSupportSubdir = "MeetingPilot/Models"

    init() {
        self.selectedModelName = UserDefaults.standard.string(forKey: Self.modelKey) ?? "small"
        if let path = Self.existingModelPath(for: selectedModelName) {
            downloadState = .ready(path: path)
        }
    }

    var isReady: Bool {
        if case .ready = downloadState { return true }
        return false
    }

    var localModelPath: String? {
        if case .ready(let path) = downloadState { return path }
        return nil
    }

    // MARK: - Download

    func downloadSelectedModel() async {
        let modelName = selectedModelName
        if let existing = Self.existingModelPath(for: modelName) {
            await MainActor.run { downloadState = .ready(path: existing) }
            return
        }

        await MainActor.run { downloadState = .downloading(progress: 0) }

        do {
            let folder = try Self.modelsDirectory()

            // Run the download off MainActor to avoid potential deadlocks
            // when WhisperKit does post-download processing.
            let modelPath: String = try await Task.detached {
                let modelURL = try await WhisperKit.download(
                    variant: modelName,
                    downloadBase: folder
                ) { progress in
                    Task { @MainActor in
                        self.downloadState = .downloading(progress: progress.fractionCompleted)
                    }
                }
                return modelURL.path
            }.value

            await MainActor.run { downloadState = .ready(path: modelPath) }
        } catch {
            // Download may have succeeded even if post-processing errored
            if let existing = Self.existingModelPath(for: modelName) {
                await MainActor.run { downloadState = .ready(path: existing) }
            } else {
                await MainActor.run { downloadState = .failed(message: error.localizedDescription) }
            }
        }
    }

    func deleteModel(_ modelId: String) {
        guard let dir = try? Self.modelsDirectory() else { return }
        let modelDir = dir.appendingPathComponent(modelId)
        try? FileManager.default.removeItem(at: modelDir)
        if modelId == selectedModelName {
            downloadState = .notDownloaded
        }
    }

    // MARK: - WeSpeaker Speaker Embedding Model

    private static let wespeakerRepo = "aufklarer/WeSpeaker-ResNet34-LM-CoreML"
    private static let wespeakerModelFile = "wespeaker.mlmodelc"
    @Published var speakerModelState: ModelDownloadState = .notDownloaded

    var speakerModelPath: String? {
        if case .ready(let path) = speakerModelState { return path }
        return nil
    }

    func checkSpeakerModel() {
        if let path = Self.existingSpeakerModelPath() {
            speakerModelState = .ready(path: path)
        }
    }

    func downloadSpeakerModel() async {
        if let existing = Self.existingSpeakerModelPath() {
            await MainActor.run { speakerModelState = .ready(path: existing) }
            return
        }

        await MainActor.run { speakerModelState = .downloading(progress: 0) }

        do {
            let destDir = try Self.modelsDirectory()
                .appendingPathComponent("wespeaker", isDirectory: true)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            let modelcDir = destDir.appendingPathComponent(Self.wespeakerModelFile, isDirectory: true)

            // Download from Hugging Face using URLSession
            let filesToDownload = [
                "wespeaker.mlmodelc/coremldata.bin",
                "wespeaker.mlmodelc/metadata.json",
                "wespeaker.mlmodelc/model.mil",
                "wespeaker.mlmodelc/weights/weight.bin",
                "wespeaker.mlmodelc/analytics/coremldata.bin",
                "config.json",
            ]

            try FileManager.default.createDirectory(
                at: modelcDir.appendingPathComponent("weights"),
                withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: modelcDir.appendingPathComponent("analytics"),
                withIntermediateDirectories: true)

            let total = filesToDownload.count
            for (index, file) in filesToDownload.enumerated() {
                let urlString = "https://huggingface.co/\(Self.wespeakerRepo)/resolve/main/\(file)"
                guard let url = URL(string: urlString) else { continue }

                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    throw NSError(domain: "ModelManager", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to download \(file)"])
                }

                let localPath = destDir.appendingPathComponent(file)
                try data.write(to: localPath)

                let progress = Double(index + 1) / Double(total)
                await MainActor.run { speakerModelState = .downloading(progress: progress) }
            }

            let finalPath = modelcDir.path
            await MainActor.run { speakerModelState = .ready(path: finalPath) }
            mplog("WeSpeaker model downloaded to \(finalPath)")
        } catch {
            if let existing = Self.existingSpeakerModelPath() {
                await MainActor.run { speakerModelState = .ready(path: existing) }
            } else {
                await MainActor.run { speakerModelState = .failed(message: error.localizedDescription) }
                mplog("WeSpeaker download failed: \(error.localizedDescription)")
            }
        }
    }

    private static func existingSpeakerModelPath() -> String? {
        guard let dir = try? modelsDirectory() else { return nil }
        let modelcPath = dir
            .appendingPathComponent("wespeaker")
            .appendingPathComponent(wespeakerModelFile)
        let fm = FileManager.default
        if fm.fileExists(atPath: modelcPath.appendingPathComponent("coremldata.bin").path) {
            return modelcPath.path
        }
        return nil
    }

    // MARK: - Paths

    private static func modelsDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent(appSupportSubdir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func existingModelPath(for modelName: String) -> String? {
        guard let dir = try? modelsDirectory() else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return nil }

        // WhisperKit downloads to a nested structure like:
        //   Models/models/argmaxinc/whisperkit-coreml/openai_whisper-tiny/
        // We search recursively for a directory whose name contains the model name
        // AND has CoreML model files inside.
        let needle = modelName.lowercased()
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            guard let isDir = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDir else { continue }
            let name = url.lastPathComponent.lowercased()
            if name.contains(needle) {
                let children = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
                let hasModel = children.contains { $0.hasSuffix(".mlmodelc") || $0 == "config.json" }
                if hasModel { return url.path }
            }
        }
        return nil
    }
}
