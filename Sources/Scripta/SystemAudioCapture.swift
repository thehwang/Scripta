import CoreGraphics
import CoreMedia
import Foundation
import ScriptaCore
import ScreenCaptureKit

final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    enum CaptureError: Error, LocalizedError, Equatable {
        case permissionDenied
        case noDisplayFound
        case streamNotInitialized

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Screen Recording permission is required. Add Scripta in System Settings → Privacy & Security → Screen Recording."
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
    private let sampleQueue = DispatchQueue(label: "scripta.system-audio.sample")

    /// Best-effort screen recording permission check.
    /// NOTE: CGPreflightScreenCaptureAccess is unreliable for self-signed
    /// apps — it may return false even when permission is granted. Use only
    /// as a UI hint, never as a gate.
    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            mplog("SystemAudioCapture: SCShareableContent OK — \(content.displays.count) displays, \(content.applications.count) apps")
        } catch {
            mplog("SystemAudioCapture: SCShareableContent FAILED — \(error)")
            // On macOS 15, a fresh Xcode build may need the user to manually
            // add the app in System Settings → Screen Recording, then restart.
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
            mplog("SystemAudioCapture: stream capture started")
        } catch {
            mplog("SystemAudioCapture: startCapture FAILED — \(error)")
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
