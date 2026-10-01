import AVFoundation
import Foundation

@MainActor
final class AudioLevels: ObservableObject {
    @Published private(set) var microphone: Float = 0
    @Published private(set) var system: Float = 0

    func update(_ value: Float, systemAudio: Bool) {
        let current = systemAudio ? system : microphone
        let next = max(value, current * 0.72)
        guard abs(next - current) >= 0.005 else { return }
        if systemAudio { system = next } else { microphone = next }
    }

    func decay() {
        let microphoneNext = microphone < 0.005 ? 0 : microphone * 0.82
        let systemNext = system < 0.005 ? 0 : system * 0.82
        if microphoneNext != microphone { microphone = microphoneNext }
        if systemNext != system { system = systemNext }
    }

    func reset() {
        if microphone != 0 { microphone = 0 }
        if system != 0 { system = 0 }
    }

    var isActive: Bool { microphone > 0 || system > 0 }
}

@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isFinalizingRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    let meters = AudioLevels()
    @Published private(set) var includesSystemAudio = false
    @Published private(set) var lastStartWarning: String?
    @Published private(set) var activeMicrophoneName: String?
    @Published private(set) var silenceWarning = false

    private static let silenceThreshold: Float = 0.01
    private static let silenceInterval: TimeInterval = 60
    private var lastAudibleAt: Date?
    private var silenceAcknowledged = false

    var preferredMicrophoneUID: String?

    private var microphoneCapture: MicrophoneCapture?
    private var previewMicrophoneCapture: MicrophoneCapture?
    private var microphoneURL: URL?
    private var systemAudioURL: URL?
    private var timer: Timer?
    private var previewDecayTimer: Timer?
    private var startedAt: Date?
    private let systemAudioRecorder = SystemAudioRecorder()
    private let previewSystemAudioRecorder = SystemAudioRecorder()
    private var didAttemptPreviewPermissions = false

    static func suggestedSessionFolderName() -> String {
        let stamp = localizedFileNameTimestamp()
        return URL(fileURLWithPath: String.localizedStringWithFormat(
            String(localized: "recordings.fileName", defaultValue: "Recording_%@.caf"), stamp
        )).deletingPathExtension().lastPathComponent
    }

    init() {
        systemAudioRecorder.onLevel = { [weak self] newLevel in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateLevel(newLevel, systemAudio: true)
                self.noteRecordingLevel(newLevel)
            }
        }
        previewSystemAudioRecorder.onLevel = { [weak self] newLevel in
            Task { @MainActor [weak self] in
                guard let self, !self.isRecording else { return }
                self.updateLevel(newLevel, systemAudio: true)
            }
        }
    }

    func start(sessionFolderName: String? = nil) async throws {
        guard !isRecording else { return }
        await stopPreviewMonitoring()
        try await RecordingPermissions.ensureMicrophoneAccess()
        let recordingsFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(String(localized: "recordings.folderName", defaultValue: "WhisperMLX Recordings"), isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        let sessionName = Self.sanitizedSessionFolderName(sessionFolderName)
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
                self.updateLevel(newLevel, systemAudio: false)
                self.noteRecordingLevel(newLevel)
            }
        }
        let activeMicrophone = try capture.start(
            preferredDeviceID: preferredMicrophoneUID,
            outputURL: microphoneURL,
            enableFileWriting: true
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
        lastAudibleAt = .now
        silenceAcknowledged = false
        if silenceWarning { silenceWarning = false }
        elapsed = 0
        meters.reset()
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date.now.timeIntervalSince(startedAt)
                self.checkSilence()
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
        silenceWarning = false
        lastAudibleAt = nil
        isFinalizingRecording = true
        elapsed = 0
        meters.reset()
        activeMicrophoneName = nil

        defer {
            isFinalizingRecording = false
        }

        guard didWriteMicrophoneAudio, let microphoneURL else {
            await startPreviewMonitoringIfPossible()
            return nil
        }

        defer {
            Task { @MainActor [weak self] in
                await self?.startPreviewMonitoringIfPossible()
            }
        }

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

    func continueAfterSilence() {
        silenceWarning = false
        silenceAcknowledged = true
    }

    private func noteRecordingLevel(_ level: Float) {
        guard isRecording, level >= Self.silenceThreshold else { return }
        lastAudibleAt = .now
        silenceAcknowledged = false
        if silenceWarning { silenceWarning = false }
    }

    private func checkSilence() {
        guard isRecording, !silenceWarning, !silenceAcknowledged,
              let lastAudibleAt,
              Date.now.timeIntervalSince(lastAudibleAt) >= Self.silenceInterval else { return }
        silenceWarning = true
    }

    func startPreviewMonitoringIfPossible() async {
        guard !isRecording else { return }
        meters.reset()

        if previewMicrophoneCapture == nil, RecordingPermissions.hasMicrophoneAccess() {
            let capture = MicrophoneCapture { [weak self] newLevel in
                Task { @MainActor [weak self] in
                    guard let self, !self.isRecording else { return }
                    self.updateLevel(newLevel, systemAudio: false)
                }
            }
            do {
                _ = try capture.start(
                    preferredDeviceID: preferredMicrophoneUID,
                    outputURL: nil,
                    enableFileWriting: false
                )
                previewMicrophoneCapture = capture
            } catch {
                NSLog("WhisperMLX UI: could not start microphone preview: \(error.localizedDescription)")
            }
        }

        if RecordingPermissions.hasSystemAudioAccess(),
           !previewSystemAudioRecorder.isCapturing {
            do {
                try await previewSystemAudioRecorder.start(to: nil)
            } catch {
                NSLog("WhisperMLX UI: could not start system-audio preview: \(error.localizedDescription)")
            }
        }

        // The first non-silent capture buffer starts the decay timer.
    }

    func preparePreviewMonitoring() async {
        guard !didAttemptPreviewPermissions else {
            await startPreviewMonitoringIfPossible()
            return
        }

        didAttemptPreviewPermissions = true
        _ = await RecordingPermissions.requestMicrophoneAccessIfNeeded()
        _ = RecordingPermissions.requestSystemAudioAccessIfNeeded()
        await startPreviewMonitoringIfPossible()
    }

    func refreshPreviewMonitoring() async {
        await stopPreviewMonitoring()
        await startPreviewMonitoringIfPossible()
    }

    private func stopPreviewMonitoring() async {
        _ = previewMicrophoneCapture?.stop()
        previewMicrophoneCapture = nil
        await previewSystemAudioRecorder.stop()
        previewDecayTimer?.invalidate()
        previewDecayTimer = nil
        if !isRecording {
            meters.reset()
        }
    }

    private func updateLevel(_ value: Float, systemAudio: Bool) {
        guard value >= 0.005 else { return }
        meters.update(value, systemAudio: systemAudio)
        if meters.isActive && previewDecayTimer == nil { startPreviewDecayTimer() }
    }

    private func startPreviewDecayTimer() {
        guard previewDecayTimer == nil else { return }
        previewDecayTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.meters.decay()
                if !self.meters.isActive {
                    self.previewDecayTimer?.invalidate()
                    self.previewDecayTimer = nil
                }
            }
        }
    }

    private static func localizedFileNameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: .now)
    }

    private static func sanitizedSessionFolderName(_ input: String?) -> String {
        let fallback = suggestedSessionFolderName()
        guard let input else { return fallback }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        let invalidCharacters = CharacterSet(charactersIn: "/:")
        let cleanedScalars = trimmed.unicodeScalars.map { scalar in
            invalidCharacters.contains(scalar) ? "-" : Character(scalar)
        }
        let cleaned = String(cleanedScalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }
}

private final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "local.whispermlx.microphone-capture")
    private let onLevel: (Float) -> Void
    private var writer: MicrophoneFileWriter?
    private var isWritingEnabled = false

    init(onLevel: @escaping (Float) -> Void) {
        self.onLevel = onLevel
    }

    func start(preferredDeviceID: String?, outputURL: URL?, enableFileWriting: Bool) throws -> AudioInputDevice {
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
        isWritingEnabled = enableFileWriting
        writer = outputURL.map(MicrophoneFileWriter.init(outputURL:))
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
            isWritingEnabled = false
        }
        return wroteAudio
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = sampleBuffer.asPCMBuffer() else { return }
        if isWritingEnabled {
            writer?.write(buffer)
        }
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
            // Some audio drivers intermittently emit non-finite floating-point
            // samples. Converting both sources to signed integer PCM before
            // mixing makes those samples safe for AAC encoding.
            "-filter_complex", "[0:a]aformat=sample_fmts=s16[system];[1:a]aformat=sample_fmts=s16[microphone];[system][microphone]amix=inputs=2:duration=longest:normalize=0",
            "-ar", "16000", "-ac", "1", "-c:a", "aac", "-b:a", "64k", output.path
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        do {
            try process.run()
        } catch {
            throw error
        }

        await Task.detached(priority: .userInitiated) {
            process.waitUntilExit()
        }.value

        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
                NSLog("WhisperMLX UI: ffmpeg mix failed: \(errorOutput)")
            }
            throw MixerError.mixingFailed
        }

        try await waitForStableOutput(at: output)
    }

    private static func waitForStableOutput(at output: URL) async throws {
        let fileManager = FileManager.default
        var lastSize: Int64 = -1
        var stableMatches = 0

        for _ in 0..<20 {
            guard let attributes = try? fileManager.attributesOfItem(atPath: output.path),
                  let fileSize = attributes[.size] as? NSNumber else {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }

            let size = fileSize.int64Value
            if size > 0, size == lastSize {
                stableMatches += 1
                if stableMatches >= 2 {
                    return
                }
            } else {
                stableMatches = 0
            }

            lastSize = size
            try await Task.sleep(for: .milliseconds(100))
        }

        throw MixerError.mixingFailed
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
