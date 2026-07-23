import Foundation
import Observation

@MainActor
@Observable
final class TranscriptionController {
    enum Model: String, CaseIterable, Identifiable {
        case largeV3 = "large-v3"
        case turbo = "large-v3-turbo"
        case small

        var id: String { rawValue }

        var title: String {
            switch self {
            case .largeV3: String(localized: "model.largeV3")
            case .turbo: String(localized: "model.turbo")
            case .small: String(localized: "model.small")
            }
        }

        var repository: String {
            switch self {
            case .largeV3: "mlx-community/whisper-large-v3-mlx"
            case .turbo: "mlx-community/whisper-large-v3-turbo"
            case .small: "mlx-community/whisper-small-mlx"
            }
        }
    }

    enum VADMethod: String, CaseIterable, Identifiable {
        case pyannote, silero

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pyannote: String(localized: "vad.pyannote")
            case .silero: String(localized: "vad.silero")
            }
        }
    }

    enum Status: Equatable {
        case ready
        case running
        case succeeded(URL)
        case failed(String)
        case cancelled
    }

    var inputURL: URL?
    var model: Model = .largeV3
    var vadMethod: VADMethod = .pyannote
    var diarizationEnabled: Bool
    var diarizationModelPath: String
    var preferredMicrophoneUID: String?
    /// nil lets pyannote determine the number of speakers.
    var speakerCount: Int?
    var status: Status = .ready
    var log = ""
    /// Percentage reported by WhisperMLX while it processes audio chunks.
    var progress: Double?
    let recorder = AudioRecorder()

    private var process: Process?
    private var scopedURL: URL?
    private static let progressPattern = try! NSRegularExpression(pattern: "Transcribing:\\s*(\\d{1,3})%")

    init() {
        let initialDiarizationModelPath = LocalDiarizationModelStore.load()
        let initialMicrophoneUID = AudioInputDeviceStore.load()
        diarizationModelPath = initialDiarizationModelPath
        preferredMicrophoneUID = initialMicrophoneUID
        recorder.preferredMicrophoneUID = initialMicrophoneUID
        // A saved token or a local pipeline directory are sufficient for the
        // default; the secret value is only retrieved when it is actually used.
        diarizationEnabled = TokenStore.exists() || Self.isUsableDiarizationModelPath(initialDiarizationModelPath)
    }

    var outputURL: URL? {
        inputURL?.deletingPathExtension()
            .appendingPathExtension(String(localized: "file.outputExtension", defaultValue: "transcript"))
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    var canStart: Bool {
        inputURL != nil && !isRunning
    }

    func selectFile(_ url: URL) {
        inputURL = url
        status = .ready
        log = ""
    }

    func start() {
        guard let inputURL else { return }
        guard resolveCLI() != nil else {
            status = .failed(String(localized: "error.whisperMLXNotInstalled"))
            return
        }
        guard ModelManager.isInstalled(model) else {
            status = .failed(String(localized: "error.modelNotInstalled"))
            return
        }

        let localDiarizationModel = validatedDiarizationModelPath()
        if diarizationEnabled && !diarizationModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && localDiarizationModel == nil {
            status = .failed(String(localized: "error.diarizationModelPathInvalid"))
            return
        }
        if diarizationEnabled && localDiarizationModel == nil && TokenStore.load().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = .failed(String(localized: "error.huggingFaceTokenRequired"))
            log = String(localized: "log.huggingFaceTokenRequired") + "\n"
            return
        }
        guard let executableURL = resolveCLI() else { return }

        let scoped = inputURL.startAccessingSecurityScopedResource()
        if scoped { scopedURL = inputURL }

        var arguments = [inputURL.path, "--model", model.rawValue, "--vad_method", vadMethod.rawValue]
        if diarizationEnabled {
            arguments.append("--diarize")
            if let localDiarizationModel {
                arguments += ["--diarize_model", localDiarizationModel]
            }
            if let speakerCount {
                arguments += ["--min_speakers", "\(speakerCount)", "--max_speakers", "\(speakerCount)"]
            }
        }

        let newProcess = Process()
        let outputPipe = Pipe()
        newProcess.executableURL = executableURL
        newProcess.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let bundledBin = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin").path
        environment["PATH"] = "\(bundledBin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if diarizationEnabled && localDiarizationModel == nil {
            let token = TokenStore.load()
            if !token.isEmpty {
                environment["HF_TOKEN"] = token
            }
        }
        newProcess.environment = environment
        newProcess.standardOutput = outputPipe
        newProcess.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.log.append(text)
                self.updateProgress()
            }
        }

        newProcess.terminationHandler = { [weak self] process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.scopedURL?.stopAccessingSecurityScopedResource()
                self.scopedURL = nil
                self.process = nil
                self.progress = nil
                if process.terminationReason == .uncaughtSignal {
                    self.status = .cancelled
                } else if process.terminationStatus == 0, let outputURL = self.outputURL {
                    self.status = .succeeded(outputURL)
                } else {
                    self.status = .failed(
                        String.localizedStringWithFormat(
                            String(localized: "error.transcriptionExitCode"),
                            process.terminationStatus
                        )
                    )
                }
            }
        }

        do {
            try newProcess.run()
            process = newProcess
            status = .running
            progress = 0
            log = String(localized: "log.transcriptionStarted", defaultValue: "Transcription started ...") + "\n"
        } catch {
            inputURL.stopAccessingSecurityScopedResource()
            scopedURL = nil
            status = .failed(
                String.localizedStringWithFormat(
                    String(localized: "error.whisperMLXLaunchFailed"),
                    error.localizedDescription
                )
            )
        }
    }

    func cancel() {
        process?.terminate()
    }

    func startRecording() {
        Task {
            do {
                try await recorder.start()
                log = String(localized: "log.recordingRunning") + "\n"
                if let warning = recorder.lastStartWarning, !warning.isEmpty {
                    log += warning + "\n"
                }
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func stopRecording() {
        Task {
            guard let url = await recorder.stop() else {
                status = .failed(String(localized: "error.audioMixingFailed"))
                return
            }
            selectFile(url)
            log = String.localizedStringWithFormat(
                String(localized: "log.recordingSaved"),
                url.lastPathComponent
            )
        }
    }

    private func resolveCLI() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/bin/whispermlx"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".local/bin/whispermlx"),
            URL(fileURLWithPath: "/Applications/WhisperMLX UI.app/Contents/Resources/bin/whispermlx")
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func updateProgress() {
        let range = NSRange(log.startIndex..., in: log)
        guard let match = Self.progressPattern.matches(in: log, range: range).last,
              let valueRange = Range(match.range(at: 1), in: log),
              let value = Double(log[valueRange]) else { return }
        progress = min(max(value, 0), 100)
    }

    private func hasLocalDiarizationModel() -> Bool {
        Self.isUsableDiarizationModelPath(diarizationModelPath)
    }

    private func validatedDiarizationModelPath() -> String? {
        let trimmedPath = diarizationModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isUsableDiarizationModelPath(trimmedPath) ? trimmedPath : nil
    }

    private static func isUsableDiarizationModelPath(_ path: String) -> Bool {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return false }

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: trimmedPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
