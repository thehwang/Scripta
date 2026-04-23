import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    enum CaptureError: Error, LocalizedError, Equatable {
        case permissionDenied
        case noDisplayFound
        case streamNotInitialized

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Screen Recording permission is required for system audio capture."
            case .noDisplayFound:
                return "No display found for ScreenCaptureKit content filter."
            case .streamNotInitialized:
                return "System audio stream is not initialized."
            }
        }
    }

    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "meetingpilot.system-audio.sample")

    func start() async throws {
        // Don't use CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess —
        // they are unreliable with ad-hoc signed apps. Instead, let SCShareableContent
        // trigger the system permission prompt directly.

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.permissionDenied
        }

        guard let display = content.displays.first else {
            throw CaptureError.noDisplayFound
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        config.queueDepth = 8
        config.width = 2
        config.height = 2

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

        do {
            try await newStream.startCapture()
        } catch {
            throw CaptureError.permissionDenied
        }

        self.stream = newStream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        onAudioSampleBuffer?(sampleBuffer)
    }
}
