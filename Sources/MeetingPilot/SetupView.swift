import SwiftUI

struct SetupView: View {
    @ObservedObject var modelManager: ModelManager
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            header
            modelList
            statusArea
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 480)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("Meeting Pilot Setup")
                .font(.system(size: 22, weight: .semibold))
            Text("Choose a Whisper model for speech transcription.\nLarger models are more accurate but use more disk space and memory.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private var modelList: some View {
        VStack(spacing: 8) {
            ForEach(ModelManager.availableModels) { model in
                modelRow(model)
            }
        }
    }

    private func modelRow(_ model: WhisperModelInfo) -> some View {
        let isSelected = modelManager.selectedModelName == model.id
        return HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .fontWeight(.medium)
                    if model.isRecommended {
                        Text("Recommended")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                Text("\(model.sizeDescription) — \(model.accuracyDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(10)
        .background(isSelected ? Color.blue.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            modelManager.selectedModelName = model.id
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
                        Text("Downloading \(modelManager.selectedModelName)...")
                            .font(.callout)
                    }
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .ready:
                VStack(spacing: 10) {
                    Label("Model ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.medium))
                    Button("Start Meeting Pilot") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

            case .failed(let message):
                VStack(spacing: 8) {
                    Label("Download failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    downloadButton
                }
            }
        }
    }

    private var downloadButton: some View {
        Button {
            Task {
                await modelManager.downloadSelectedModel()
            }
        } label: {
            Label("Download Model", systemImage: "arrow.down.circle")
                .frame(minWidth: 200)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}
