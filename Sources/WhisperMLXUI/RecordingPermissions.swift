import AVFoundation
import CoreGraphics

/// Keeps the two recording permissions separate. Microphone access is managed
/// by AVFoundation, while capturing system audio requires screen-capture access.
enum RecordingPermissions {
    static func ensureMicrophoneAccess() async throws {
        // AVAudioApplication is the current microphone-permission API on
        // macOS 14+. On recent macOS versions it stays in sync with the
        // Privacy & Security switch used by AVAudioEngine, whereas the older
        // AVCaptureDevice status can occasionally report a stale denial.
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return
            case .undetermined:
                guard await requestAudioApplicationPermission() else {
                    throw RecorderError.microphoneUnavailable
                }
                return
            case .denied:
                throw RecorderError.microphoneUnavailable
            @unknown default:
                throw RecorderError.microphoneUnavailable
            }
        }

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

    @available(macOS 14.0, *)
    private static func requestAudioApplicationPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static func ensureSystemAudioAccess() -> Bool {
        guard !CGPreflightScreenCaptureAccess() else { return true }
        return CGRequestScreenCaptureAccess()
    }
}
