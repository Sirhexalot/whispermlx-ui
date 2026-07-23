import AVFoundation
import CoreGraphics

/// Keeps the two recording permissions separate. Microphone access is managed
/// by AVFoundation, while capturing system audio requires screen-capture access.
enum RecordingPermissions {
    static func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw RecorderError.microphoneUnavailable
            }
        case .denied, .restricted:
            throw RecorderError.microphoneUnavailable
        @unknown default:
            throw RecorderError.microphoneUnavailable
        }
    }

    static func ensureSystemAudioAccess() -> Bool {
        guard !CGPreflightScreenCaptureAccess() else { return true }
        return CGRequestScreenCaptureAccess()
    }
}
