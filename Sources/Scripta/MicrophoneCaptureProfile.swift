import AppKit
import CoreAudio
import ScriptaCore

enum EchoCancellationMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case on = "On"
    case off = "Off"

    var id: String { rawValue }

    static let defaultsKey = "Scripta.echoCancellationMode"

    static var stored: EchoCancellationMode {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let mode = EchoCancellationMode(rawValue: raw) else {
            return .auto
        }
        return mode
    }

    var helpText: String {
        switch self {
        case .auto:
            return "Automatically enable echo cancellation with speakers, and disable it for meeting apps or headphones."
        case .on:
            return "Always enable echo cancellation. Best for solo recording with speakers; may block Teams and Zoom microphones."
        case .off:
            return "Always disable echo cancellation. Best when using Teams, Zoom, or browser meetings; mic may pick up speaker audio."
        }
    }
}

struct DetectedMeetingApp: Equatable {
    let displayName: String
    let bundleIdentifier: String
}

enum MicrophoneCaptureProfile {
    case meetingAppSharing(apps: [DetectedMeetingApp])
    case headphones
    case speakerEchoCancellation

    var usesVoiceProcessing: Bool {
        switch self {
        case .meetingAppSharing, .headphones:
            return false
        case .speakerEchoCancellation:
            return true
        }
    }

    var logMessage: String {
        switch self {
        case .meetingAppSharing(let apps):
            let names = apps.map(\.displayName).joined(separator: ", ")
            return "Meeting app detected (\(names)); sharing microphone with Voice Processing disabled"
        case .headphones:
            return "Headphones detected; Voice Processing disabled"
        case .speakerEchoCancellation:
            return "Speakers detected; Voice Processing enabled for echo cancellation"
        }
    }

    static func detect() -> MicrophoneCaptureProfile {
        let meetingApps = MeetingAppDetector.runningApps()
        if !meetingApps.isEmpty {
            return .meetingAppSharing(apps: meetingApps)
        }
        if AudioRouteDetector.isUsingHeadphones() {
            return .headphones
        }
        return .speakerEchoCancellation
    }
}

struct ResolvedMicrophoneCapture {
    let usesVoiceProcessing: Bool
    let statusDetail: String
    let logMessage: String

    static func resolve(mode: EchoCancellationMode) -> ResolvedMicrophoneCapture {
        switch mode {
        case .on:
            return ResolvedMicrophoneCapture(
                usesVoiceProcessing: true,
                statusDetail: "Echo cancellation: On",
                logMessage: "Echo cancellation forced on"
            )
        case .off:
            return ResolvedMicrophoneCapture(
                usesVoiceProcessing: false,
                statusDetail: "Echo cancellation: Off",
                logMessage: "Echo cancellation forced off"
            )
        case .auto:
            let profile = MicrophoneCaptureProfile.detect()
            return ResolvedMicrophoneCapture(
                usesVoiceProcessing: profile.usesVoiceProcessing,
                statusDetail: autoStatusDetail(for: profile),
                logMessage: "Echo cancellation auto — \(profile.logMessage)"
            )
        }
    }

    private static func autoStatusDetail(for profile: MicrophoneCaptureProfile) -> String {
        switch profile {
        case .meetingAppSharing(let apps):
            let names = apps.map(\.displayName).joined(separator: ", ")
            return "Echo cancellation: Auto (off — \(names))"
        case .headphones:
            return "Echo cancellation: Auto (off — headphones)"
        case .speakerEchoCancellation:
            return "Echo cancellation: Auto (on — speakers)"
        }
    }
}

private enum MeetingAppDetector {
    private static let knownApps: [(bundleID: String, displayName: String)] = [
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("us.zoom.xos", "Zoom"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("com.apple.FaceTime", "FaceTime"),
    ]

    static func runningApps() -> [DetectedMeetingApp] {
        let runningIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        var seenNames = Set<String>()
        return knownApps.compactMap { app in
            guard runningIDs.contains(app.bundleID), !seenNames.contains(app.displayName) else {
                return nil
            }
            seenNames.insert(app.displayName)
            return DetectedMeetingApp(displayName: app.displayName, bundleIdentifier: app.bundleID)
        }
    }
}

private enum AudioRouteDetector {
    static func isUsingHeadphones() -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return false }

        if let transport = transportType(for: deviceID) {
            switch transport {
            case kAudioDeviceTransportTypeBluetooth,
                 kAudioDeviceTransportTypeBluetoothLE,
                 kAudioDeviceTransportTypeUSB,
                 kAudioDeviceTransportTypeHDMI:
                return true
            default:
                break
            }
        }

        if let name = deviceName(for: deviceID)?.lowercased() {
            let headphoneKeywords = ["headphone", "airpods", "earphone", "earbud", "beats"]
            if headphoneKeywords.contains(where: { name.contains($0) }) {
                return true
            }
        }

        return false
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private static func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : nil
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? name as String : nil
    }
}
