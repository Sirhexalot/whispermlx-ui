import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var includesSystemAudio = false
    @Published private(set) var lastStartWarning: String?
    @Published private(set) var activeMicrophoneName: String?

    var preferredMicrophoneUID: String?

    private var microphoneCapture: MicrophoneCapture?
    private var microphoneURL: URL?
    private var systemAudioURL: URL?
    private var timer: Timer?
    private var startedAt: Date?
    private let systemAudioRecorder = SystemAudioRecorder()

    init() {
        systemAudioRecorder.onLevel = { [weak self] newLevel in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.systemLevel = max(newLevel, self.systemLevel * 0.72)
            }
        }
    }

    func start() async throws {
        guard !isRecording else { return }
        try await RecordingPermissions.ensureMicrophoneAccess()
        let recordingsFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(String(localized: "recordings.folderName", defaultValue: "WhisperMLX Recordings"), isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        let stamp = Self.localizedFileNameTimestamp()
        let sessionName = URL(fileURLWithPath: String.localizedStringWithFormat(
            String(localized: "recordings.fileName", defaultValue: "Recording_%@.caf"), stamp
        )).deletingPathExtension().lastPathComponent
        let sessionFolder = recordingsFolder.appendingPathComponent(sessionName, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        let sourceFolder = sessionFolder.appendingPathComponent(
            String(localized: "recordings.sourceFolderName", defaultValue: "source"),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let microphoneURL = sourceFolder.appendingPathComponent(
            String(localized: "recordings.microphoneFileName", defaultValue: "Microphone.caf")
        )
        let systemURL = sourceFolder.appendingPathComponent(
            String(localized: "recordings.systemAudioFileName", defaultValue: "System Audio.caf")
        )
        let capture = MicrophoneCapture { [weak self] newLevel in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.level = max(newLevel, self.level * 0.72)
            }
        }
        let activeMicrophone = try capture.start(
            preferredDeviceID: preferredMicrophoneUID,
            outputURL: microphoneURL
        )

        do {
            try await systemAudioRecorder.start(to: systemURL)
            self.systemAudioURL = systemURL
            includesSystemAudio = true
            lastStartWarning = nil
        } catch {
            // Fall back to microphone-only recording if ScreenCaptureKit or the
            // related permission is unavailable.
            self.systemAudioURL = nil
            includesSystemAudio = false
            lastStartWarning = String(
                localized: "log.recordingMicrophoneOnly",
                defaultValue: "System audio is unavailable. Recording microphone only."
            )
        }

        microphoneCapture = capture
        self.microphoneURL = microphoneURL
        activeMicrophoneName = activeMicrophone.name
        startedAt = .now
        elapsed = 0
        level = 0
        systemLevel = includesSystemAudio ? 0 : 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date.now.timeIntervalSince(startedAt)
            }
        }
    }

    func stop() async -> URL? {
        guard isRecording else { return nil }
        timer?.invalidate(); timer = nil
        let didWriteMicrophoneAudio = microphoneCapture?.stop() == true
        microphoneCapture = nil
        await systemAudioRecorder.stop()
        isRecording = false
        elapsed = 0
        level = 0
        systemLevel = 0
        activeMicrophoneName = nil

        guard didWriteMicrophoneAudio, let microphoneURL else { return nil }
        guard let systemAudioURL else { return microphoneURL }
        let mixedURL = microphoneURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            String(localized: "recordings.mixedFileName", defaultValue: "Recording.m4a")
        )
        do {
            try await AudioMixer.mix(systemAudio: systemAudioURL, microphone: microphoneURL, output: mixedURL)
            return mixedURL
        } catch {
            NSLog("WhisperMLX UI: could not mix audio tracks: \(error.localizedDescription)")
            return nil
        }
    }

    private static func localizedFileNameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: .now)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}

private final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "local.whispermlx.microphone-capture")
    private let onLevel: (Float) -> Void
    private var writer: MicrophoneFileWriter?

    init(onLevel: @escaping (Float) -> Void) {
        self.onLevel = onLevel
    }

    func start(preferredDeviceID: String?, outputURL: URL) throws -> AudioInputDevice {
        let device: AVCaptureDevice?
        if let preferredDeviceID, !preferredDeviceID.isEmpty {
            device = AVCaptureDevice(uniqueID: preferredDeviceID)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else { throw RecorderError.microphoneUnavailable }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw RecorderError.microphoneUnavailable
        }

        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        output.setSampleBufferDelegate(self, queue: queue)
        writer = MicrophoneFileWriter(outputURL: outputURL)
        session.startRunning()
        return AudioInputDevice(
            id: device.uniqueID,
            name: device.localizedName,
            isDefault: device.uniqueID == AVCaptureDevice.default(for: .audio)?.uniqueID
        )
    }

    func stop() -> Bool {
        session.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)
        var wroteAudio = false
        queue.sync {
            wroteAudio = writer?.close() == true
            writer = nil
        }
        return wroteAudio
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = sampleBuffer.asPCMBuffer() else { return }
        writer?.write(buffer)
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(samples[index]))
        }
        onLevel(min(1, peak * 8))
    }
}

private final class MicrophoneFileWriter {
    private let outputURL: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var wroteAudio = false
    private var isClosed = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func close() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
        file = nil
        return wroteAudio
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }

        do {
            if file == nil {
                file = try AVAudioFile(forWriting: outputURL, settings: buffer.format.settings)
            }
            try file?.write(from: buffer)
            wroteAudio = true
        } catch {
            NSLog("WhisperMLX UI: could not write microphone audio: \(error.localizedDescription)")
        }
    }
}

enum RecorderError: LocalizedError {
    case microphoneUnavailable
    case microphoneSelectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            String(localized: "error.microphoneUnavailable")
        case let .microphoneSelectionFailed(name):
            String.localizedStringWithFormat(
                String(localized: "error.microphoneSelectionFailed"),
                name
            )
        }
    }
}

enum AudioMixer {
    static func mix(systemAudio: URL, microphone: URL, output: URL) async throws {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/ffmpeg").path,
            "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw MixerError.ffmpegMissing
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "-y", "-i", systemAudio.path, "-i", microphone.path,
            "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0",
            "-ar", "16000", "-ac", "1", "-c:a", "aac", "-b:a", "64k", output.path
        ]
        let stderr = Pipe()
        process.standardError = stderr
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard process.terminationStatus == 0 else { throw MixerError.mixingFailed }
    }
}

enum MixerError: LocalizedError {
    case ffmpegMissing
    case mixingFailed

    var errorDescription: String? {
        switch self {
        case .ffmpegMissing: String(localized: "error.ffmpegMissing")
        case .mixingFailed: String(localized: "error.audioMixingFailed")
        }
    }
}
