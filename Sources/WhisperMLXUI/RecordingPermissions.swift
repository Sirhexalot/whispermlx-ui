import AVFoundation
import CoreGraphics

/// Keeps the two recording permissions separate. Microphone access is managed
/// by AVFoundation, while capturing system audio requires screen-capture access.
enum RecordingPermissions {
    static func hasMicrophoneAccess() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await requestCapturePermission()
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    static func ensureMicrophoneAccess() async throws {
        // Microphone capture itself uses AVCaptureSession. Use the matching
        // AVCaptureDevice permission API so a fresh Developer ID build shows
        // macOS's microphone prompt when access is still undetermined.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await requestCapturePermission() else {
                throw RecorderError.microphoneUnavailable
            }
        case .denied, .restricted:
            throw RecorderError.microphoneUnavailable
        @unknown default:
            throw RecorderError.microphoneUnavailable
        }
    }

    private static func requestCapturePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static func ensureSystemAudioAccess() -> Bool {
        guard !CGPreflightScreenCaptureAccess() else { return true }
        return CGRequestScreenCaptureAccess()
    }

    static func hasSystemAudioAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestSystemAudioAccessIfNeeded() -> Bool {
        guard !hasSystemAudioAccess() else { return true }
        return CGRequestScreenCaptureAccess()
    }
}
