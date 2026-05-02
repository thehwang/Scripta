import Foundation
import ScriptaCore

enum OllamaConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case pulling(model: String, progress: Double)
    case ready
    case failed(message: String)
}

struct OllamaModel: Identifiable, Equatable {
    let name: String
    let size: Int64
    let modifiedAt: String

    var id: String { name }

    var sizeDescription: String {
        let gb = Double(size) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(size) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

struct RecommendedModel: Identifiable {
    let name: String
    let displayName: String
    let sizeDescription: String
    let description: String
    let isDefault: Bool

    var id: String { name }
}

final class SummaryModelManager: ObservableObject {
    @Published var connectionState: OllamaConnectionState = .disconnected
    @Published var installedModels: [OllamaModel] = []
    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: Self.modelKey) }
    }

    static let recommendedModels: [RecommendedModel] = [
        RecommendedModel(
            name: "qwen2.5:3b",
            displayName: "Qwen 2.5 3B",
            sizeDescription: "~1.9 GB",
            description: "Best for Chinese + English summaries",
            isDefault: true
        ),
        RecommendedModel(
            name: "qwen2.5:1.5b",
            displayName: "Qwen 2.5 1.5B",
            sizeDescription: "~0.9 GB",
            description: "Lightweight, fast summaries",
            isDefault: false
        ),
        RecommendedModel(
            name: "llama3.2:3b",
            displayName: "Llama 3.2 3B",
            sizeDescription: "~1.9 GB",
            description: "Strong English performance",
            isDefault: false
        ),
        RecommendedModel(
            name: "llama3.2:1b",
            displayName: "Llama 3.2 1B",
            sizeDescription: "~0.7 GB",
            description: "Smallest & fastest",
            isDefault: false
        ),
    ]

    private static let modelKey = "Scripta.ollamaModel"
    private static let baseURL = "http://localhost:11434"

    var isReady: Bool {
        connectionState == .ready && !selectedModel.isEmpty
    }

    var isConnected: Bool {
        switch connectionState {
        case .connected, .ready, .pulling:
            return true
        default:
            return false
        }
    }

    init() {
        let defaultModel = Self.recommendedModels.first(where: \.isDefault)?.name ?? "qwen2.5:3b"
        self.selectedModel = UserDefaults.standard.string(forKey: Self.modelKey) ?? defaultModel
    }

    func checkConnection() async {
        await MainActor.run { connectionState = .connecting }

        guard let url = URL(string: Self.baseURL) else {
            await MainActor.run { connectionState = .failed(message: "Invalid Ollama URL") }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                await MainActor.run { connectionState = .connected }
                await refreshModels()
            } else {
                await MainActor.run {
                    connectionState = .failed(message: "Ollama returned unexpected status")
                }
            }
        } catch {
            await MainActor.run {
                connectionState = .disconnected
            }
            mplog("Ollama connection failed: \(error.localizedDescription)")
        }
    }

    func refreshModels() async {
        guard let url = URL(string: "\(Self.baseURL)/api/tags") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                let parsed = models.compactMap { dict -> OllamaModel? in
                    guard let name = dict["name"] as? String else { return nil }
                    let size = dict["size"] as? Int64 ?? 0
                    let modified = dict["modified_at"] as? String ?? ""
                    return OllamaModel(name: name, size: size, modifiedAt: modified)
                }
                await MainActor.run {
                    self.installedModels = parsed
                    if !parsed.isEmpty {
                        if parsed.contains(where: { $0.name == selectedModel }) {
                            connectionState = .ready
                        } else {
                            selectedModel = parsed[0].name
                            connectionState = .ready
                        }
                    } else {
                        connectionState = .connected
                    }
                }
                mplog("Ollama models: \(parsed.map(\.name))")
            }
        } catch {
            mplog("Failed to list Ollama models: \(error.localizedDescription)")
        }
    }

    func pullModel(_ modelName: String) async {
        guard let url = URL(string: "\(Self.baseURL)/api/pull") else { return }

        await MainActor.run {
            connectionState = .pulling(model: modelName, progress: 0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600

        let body: [String: Any] = ["name": modelName, "stream": true]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                await MainActor.run {
                    connectionState = .failed(message: "Failed to pull model: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                return
            }

            for try await line in bytes.lines {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                if let total = json["total"] as? Int64, total > 0,
                   let completed = json["completed"] as? Int64 {
                    let progress = Double(completed) / Double(total)
                    await MainActor.run {
                        connectionState = .pulling(model: modelName, progress: progress)
                    }
                }

                if let status = json["status"] as? String, status == "success" {
                    break
                }

                if let errorMsg = json["error"] as? String {
                    await MainActor.run {
                        connectionState = .failed(message: errorMsg)
                    }
                    return
                }
            }

            await MainActor.run {
                selectedModel = modelName
            }
            await refreshModels()
            mplog("Model pulled successfully: \(modelName)")
        } catch {
            await MainActor.run {
                connectionState = .failed(message: "Pull failed: \(error.localizedDescription)")
            }
            mplog("Model pull failed: \(error.localizedDescription)")
        }
    }

    func selectModel(_ name: String) {
        selectedModel = name
        if installedModels.contains(where: { $0.name == name }) {
            connectionState = .ready
        }
    }
}
