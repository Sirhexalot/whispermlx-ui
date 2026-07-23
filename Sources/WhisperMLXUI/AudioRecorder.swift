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

    private var engine: AVAudioEngine?
    private var microphoneWriter: MicrophoneFileWriter?
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
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let activeMicrophone = try AudioInputDeviceManager.configure(node, preferredUID: preferredMicrophoneUID)
        let folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(String(localized: "recordings.folderName", defaultValue: "WhisperMLX Recordings"), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let microphoneURL = folder.appendingPathComponent(
            String.localizedStringWithFormat(String(localized: "recordings.fileName", defaultValue: "Recording_%@.caf"), stamp)
        )
        let systemURL = folder.appendingPathComponent("System_\(stamp).caf")
        let writer = MicrophoneFileWriter(outputURL: microphoneURL)

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

        // Let AVAudioEngine provide the selected device's native format. Asking
        // for a client format here can fail for microphones with a different
        // hardware format.
        node.installTap(onBus: 0, bufferSize: 2_048, format: nil) { buffer, _ in
            writer.write(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var peak: Float = 0
            for index in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(samples[index]))
            }
            // A peak display reacts promptly to speech and stays legible for
            // the relatively low levels supplied by many Mac microphones.
            let normalized = min(1, peak * 8)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.level = max(normalized, self.level * 0.72)
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        microphoneWriter = writer
        self.microphoneURL = microphoneURL
        activeMicrophoneName = activeMicrophone?.name
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
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let didWriteMicrophoneAudio = microphoneWriter?.hasWrittenAudio == true
        microphoneWriter = nil
        await systemAudioRecorder.stop()
        isRecording = false
        elapsed = 0
        level = 0
        systemLevel = 0
        activeMicrophoneName = nil

        guard didWriteMicrophoneAudio, let microphoneURL else { return nil }
        guard let systemAudioURL else { return microphoneURL }
        let mixedURL = microphoneURL.deletingPathExtension().appendingPathExtension("wav")
        do {
            try await AudioMixer.mix(systemAudio: systemAudioURL, microphone: microphoneURL, output: mixedURL)
            return mixedURL
        } catch {
            NSLog("WhisperMLX UI: could not mix audio tracks: \(error.localizedDescription)")
            return nil
        }
    }
}

private final class MicrophoneFileWriter {
    private let outputURL: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var wroteAudio = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    var hasWrittenAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wroteAudio
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

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
            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", output.path
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
