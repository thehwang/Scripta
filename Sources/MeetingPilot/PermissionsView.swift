import AVFoundation
import CoreGraphics
import Speech
import SwiftUI

struct PermissionsView: View {
    var onContinue: () -> Void

    @State private var micStatus: PermStatus = .unknown
    @State private var screenStatus: PermStatus = .unknown
    @State private var speechStatus: PermStatus = .unknown

    private enum PermStatus {
        case unknown, granted, denied
    }

    private var canContinue: Bool {
        screenStatus == .granted
    }

    private let accent = Color(red: 0.294, green: 0.557, blue: 1.0)
    private let accentLight = Color(red: 0.678, green: 0.776, blue: 1.0)
    private let subtitleGray = Color(red: 0.545, green: 0.565, blue: 0.627)
    private let dimGray = Color(red: 0.373, green: 0.384, blue: 0.420)
    private let cardBg = Color(red: 0.118, green: 0.122, blue: 0.137).opacity(0.8)

    var body: some View {
        ZStack {
            Color(red: 0.071, green: 0.075, blue: 0.090).ignoresSafeArea()

            VStack(spacing: 20) {
                heroSection
                cardsRow
                Spacer(minLength: 4)
                bottomSection
            }
            .padding(.top, 24)
        }
        .frame(minWidth: 700, maxWidth: 780, minHeight: 440, maxHeight: 520)
        .onAppear { checkAllPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkAllPermissions()
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.25), accent.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 56, height: 56)
                Image(systemName: "waveform")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(accentLight)
            }

            Text("Permissions Required")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)

            Text("To capture and transcribe your meetings, we need access to your audio sources.")
                .font(.system(size: 13))
                .foregroundStyle(subtitleGray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Cards Row (Horizontal)

    private var cardsRow: some View {
        HStack(alignment: .top, spacing: 14) {
            permissionCard(
                icon: "rectangle.inset.filled.and.person.filled",
                title: "System Audio",
                description: "Capture system-level audio for remote meeting participants.",
                isRequired: true,
                status: screenStatus,
                action: requestScreenRecording
            )
            permissionCard(
                icon: "mic.fill",
                title: "Microphone",
                description: "Capture your local microphone for your contributions.",
                isRequired: true,
                status: micStatus,
                action: requestMicrophone
            )
            permissionCard(
                icon: "waveform.badge.magnifyingglass",
                title: "Speech Recognition",
                description: "On-device speech recognition for real-time transcription.",
                isRequired: true,
                status: speechStatus,
                action: requestSpeechRecognition
            )
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Permission Card

    private func permissionCard(
        icon: String,
        title: String,
        description: String,
        isRequired: Bool,
        status: PermStatus,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(accentLight)
                }
                Spacer()
                Text(isRequired ? "Required" : "Optional")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(isRequired ? accentLight : subtitleGray)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (isRequired ? accent : Color.white).opacity(0.1),
                        in: Capsule()
                    )
            }

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(subtitleGray)
                .lineSpacing(2)
                .frame(minHeight: 36, alignment: .top)

            if status == .granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                    Text("Enabled")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text("Enable")
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
    }

    // MARK: - Bottom

    private var bottomSection: some View {
        VStack(spacing: 10) {
            Divider().background(Color.white.opacity(0.06))

            Button(action: onContinue) {
                Text("Continue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(canContinue ? .white : dimGray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        canContinue ? accent : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canContinue)
            .padding(.horizontal, 24)

            if !canContinue {
                Text("Please enable all required permissions to proceed.")
                    .font(.system(size: 10))
                    .foregroundStyle(subtitleGray)
            }

            HStack(spacing: 28) {
                featureBadge(icon: "lock.shield", text: "Privacy First")
                featureBadge(icon: "arrow.left.arrow.right", text: "End-to-End")
                featureBadge(icon: "desktopcomputer", text: "Local Processing")
            }
            .padding(.top, 2)
            .padding(.bottom, 10)
        }
    }

    private func featureBadge(icon: String, text: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(dimGray)
            Text(text)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(dimGray)
        }
    }

    // MARK: - Permission Logic

    private func checkAllPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        micStatus = mic == .authorized ? .granted : .denied

        screenStatus = CGPreflightScreenCaptureAccess() ? .granted : .denied

        let speech = SFSpeechRecognizer.authorizationStatus()
        speechStatus = speech == .authorized ? .granted : .denied
    }

    private func requestMicrophone() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    micStatus = granted ? .granted : .denied
                }
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    private func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if CGPreflightScreenCaptureAccess() {
                    screenStatus = .granted
                } else {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }
    }

    private func requestSpeechRecognition() {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { newStatus in
                DispatchQueue.main.async {
                    speechStatus = newStatus == .authorized ? .granted : .denied
                }
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
        }
    }
}
