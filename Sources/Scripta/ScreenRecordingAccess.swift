import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Speech

enum ScreenRecordingAccess {
    /// Returns true when ScreenCaptureKit can list displays (permission effectively granted).
    static func isGranted() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return !content.displays.isEmpty
        } catch {
            return false
        }
    }

    /// Mic + speech must already be authorized — scheduled auto-start must not show first-run prompts.
    static func isReadyForScheduledCapture() async -> Bool {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        guard mic == .authorized, speech == .authorized else { return false }
        return await isGranted()
    }
}
