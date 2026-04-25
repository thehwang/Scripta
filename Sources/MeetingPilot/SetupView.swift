import SwiftUI

struct SetupView: View {
    @ObservedObject var modelManager: SummaryModelManager
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            header
            modelList
            statusArea
            Spacer(minLength: 0)
            skipButton
        }
        .padding(24)
        .frame(minWidth: 540, minHeight: 520)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("AI Summary Model")
                .font(.system(size: 22, weight: .semibold))
            Text("Choose an AI model for meeting summaries and action items.\nSmaller models are faster; larger models produce better results.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private var modelList: some View {
        VStack(spacing: 8) {
            ForEach(SummaryModelManager.availableModels) { model in
                modelRow(model)
            }
        }
    }

    private func modelRow(_ model: LLMModelInfo) -> some View {
        let isSelected = modelManager.selectedModelId == model.id
        return HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .fontWeight(.medium)
                    if model.isDefault {
                        Text("Default")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                Text("\(model.sizeDescription) — \(model.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(10)
        .background(isSelected ? Color.blue.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            modelManager.selectedModelId = model.id
        }
    }

    private var statusArea: some View {
        VStack(spacing: 14) {
            switch modelManager.downloadState {
            case .notDownloaded:
                downloadButton

            case .downloading(let progress):
                VStack(spacing: 8) {
                    ProgressView(value: progress, total: 1.0) {
                        Text("Downloading model...")
                            .font(.callout)
                    }
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .loading:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading model into memory...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

            case .ready:
                VStack(spacing: 10) {
                    Label("AI model ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.medium))
                    Button("Continue to Meeting Pilot") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

            case .failed(let message):
                VStack(spacing: 8) {
                    Label("Failed to load model", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    downloadButton
                }
            }
        }
    }

    private var downloadButton: some View {
        Button {
            Task {
                await modelManager.loadSelectedModel()
            }
        } label: {
            Label("Download & Load Model", systemImage: "arrow.down.circle")
                .frame(minWidth: 220)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
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
