import SwiftUI

struct SetupView: View {
    @ObservedObject var modelManager: SummaryModelManager
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            VStack(spacing: 24) {
                header
                connectionSection
                modelSection
                Spacer(minLength: 0)
                skipButton
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(minWidth: 540, minHeight: 520)
        .onAppear {
            Task { await modelManager.checkConnection() }
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button {
                onComplete()
            } label: {
                Label("Done", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .help("Return to Scripta (⎋)")
            .accessibilityIdentifier("SetupDoneButton")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("AI Summary Setup")
                .font(.system(size: 22, weight: .semibold))
            Text("Scripta uses Ollama for local AI summaries.\nNo data leaves your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 10, height: 10)
                Text(connectionLabel)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                if !modelManager.isConnected {
                    Button("Retry") {
                        Task { await modelManager.checkConnection() }
                    }
                    .controlSize(.small)
                }
            }

            if case .disconnected = modelManager.connectionState {
                installInstructions
            }

            if case .failed(let msg) = modelManager.connectionState {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var connectionColor: Color {
        switch modelManager.connectionState {
        case .ready: return .green
        case .connected: return .green
        case .connecting: return .orange
        case .pulling: return .blue
        case .disconnected: return .red
        case .failed: return .red
        }
    }

    private var connectionLabel: String {
        switch modelManager.connectionState {
        case .disconnected: return "Ollama not running"
        case .connecting: return "Connecting..."
        case .connected: return "Ollama connected"
        case .pulling(let model, let progress):
            return "Pulling \(model)... \(Int(progress * 100))%"
        case .ready: return "Ollama ready"
        case .failed: return "Connection failed"
        }
    }

    private var installInstructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Install Ollama:")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                instructionStep(number: "1", text: "Download from ollama.com")
                HStack(spacing: 4) {
                    Spacer().frame(width: 24)
                    Link("https://ollama.com/download", destination: URL(string: "https://ollama.com/download")!)
                        .font(.system(size: 12))
                }
                instructionStep(number: "2", text: "Install and launch Ollama")
                instructionStep(number: "3", text: "Click \"Retry\" above")
            }

            Divider()

            Text("Or install via Homebrew:")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            HStack {
                Text("brew install ollama && ollama serve")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install ollama && ollama serve", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy to clipboard")
            }
        }
        .padding(.top, 4)
    }

    private func instructionStep(number: String, text: String) -> some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.blue, in: Circle())
            Text(text)
                .font(.system(size: 13))
        }
    }

    // MARK: - Model Selection

    private var modelSection: some View {
        VStack(spacing: 12) {
            if !modelManager.installedModels.isEmpty {
                installedModelList
            }

            if modelManager.isConnected {
                recommendedModelList
            }

            if case .pulling(_, let progress) = modelManager.connectionState {
                ProgressView(value: progress, total: 1.0) {
                    Text("Downloading model...")
                        .font(.callout)
                }
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if modelManager.isReady {
                VStack(spacing: 10) {
                    Label("AI model ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.medium))
                    Button("Continue to Scripta") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    private var installedModelList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Installed Models")
                .font(.system(size: 13, weight: .semibold))

            ForEach(modelManager.installedModels) { model in
                installedModelRow(model)
            }
        }
    }

    private func installedModelRow(_ model: OllamaModel) -> some View {
        let isSelected = modelManager.selectedModel == model.name
        let metadata = SummaryModelManager.recommendedModels.first(where: { $0.name == model.name })
        let contextLabel: String = {
            if let metadata { return metadata.contextDescription }
            let inferredCtx = SummaryModelManager.contextWindow(for: model.name)
            return inferredCtx >= 1024 ? "\(inferredCtx / 1024)K ctx" : "\(inferredCtx) ctx"
        }()

        return Button {
            modelManager.selectModel(model.name)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .fontWeight(.medium)
                        if metadata?.isNew == true {
                            Text("NEW")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.18), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }
                    Text("\(model.sizeDescription) · \(contextLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(10)
            .background(isSelected ? Color.blue.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select model \(model.name)")
        .accessibilityIdentifier("InstalledModel.\(model.name)")
    }

    private var recommendedModelList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recommended Models (click to download)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(SummaryModelManager.recommendedModels.filter { rec in
                !modelManager.installedModels.contains(where: { $0.name == rec.name })
            }) { model in
                recommendedModelRow(model)
            }
        }
    }

    private func recommendedModelRow(_ model: RecommendedModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.blue)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .fontWeight(.medium)
                    if model.isDefault {
                        Text("Recommended")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                    if model.isNew {
                        Text("NEW")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text("\(model.sizeDescription) · \(model.contextDescription) — \(model.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Pull") {
                Task { await modelManager.pullModel(model.name) }
            }
            .controlSize(.small)
            .disabled(!modelManager.isConnected || isPulling)
        }
        .padding(10)
        .background(Color.gray.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var isPulling: Bool {
        if case .pulling = modelManager.connectionState { return true }
        return false
    }

    private var skipButton: some View {
        Button("Skip — use transcription only") {
            onComplete()
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }
}
