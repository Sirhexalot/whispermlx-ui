import Darwin
import Foundation
import Observation
import UniformTypeIdentifiers

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

    enum TranscriptionLanguage: String, CaseIterable, Identifiable {
        case german
        case automatic
        case english

        var id: String { rawValue }

        var title: String {
            switch self {
            case .german:
                String(localized: "transcription.language.german")
            case .automatic:
                String(localized: "transcription.language.automatic")
            case .english:
                String(localized: "transcription.language.english")
            }
        }

        var whisperLanguageCode: String? {
            switch self {
            case .german:
                "de"
            case .automatic:
                nil
            case .english:
                "en"
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
    var transcriptionLanguage: TranscriptionLanguage
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
        let initialTranscriptionLanguage = TranscriptionLanguageStore.load()
        diarizationModelPath = initialDiarizationModelPath
        preferredMicrophoneUID = initialMicrophoneUID
        transcriptionLanguage = initialTranscriptionLanguage
        recorder.preferredMicrophoneUID = initialMicrophoneUID
        // A saved token or a local pipeline directory are sufficient for the
        // default; the secret value is only retrieved when it is actually used.
        diarizationEnabled = TokenStore.exists() || Self.isUsableDiarizationModelPath(initialDiarizationModelPath)
    }

    var outputURL: URL? {
        inputURL?.deletingPathExtension()
            .appendingPathExtension(String(localized: "file.outputExtension", defaultValue: "transcript"))
    }

    /// True after the audio files of a successful transcription were removed.
    var audioDeleted = false

    /// Set when removing the audio failed, so the interface can surface it.
    var deletionErrorMessage: String?

    /// True when the transcript output folder was actually written to disk with
    /// at least one visible result file.
    var hasSavedTranscript: Bool {
        guard let outputURL else { return false }
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: outputURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                return true
            }
        }
        return false
    }

    /// The recording session folder that contains the transcribed audio, when
    /// the input was produced by the built-in recorder. Imported files return
    /// nil so only the selected file itself is treated as audio.
    var recordingSessionFolder: URL? {
        guard let inputURL else { return nil }
        return Self.sessionFolder(containing: inputURL, recordingsRoots: AudioRecorder.knownRecordingsFolderURLs())
    }

    /// Finds the session folder that owns `fileURL`. The file must live below a
    /// known recordings root and the first path component below it must look
    /// like one of our sessions (session marker or a source subfolder). This
    /// keeps imported files outside the recordings folders untouched.
    static func sessionFolder(containing fileURL: URL, recordingsRoots: [URL]) -> URL? {
        let fileManager = FileManager.default
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let sourceNames = AudioRecorder.knownSourceFolderNames()
        for root in recordingsRoots {
            let rootURL = root.standardizedFileURL
            let rootComponents = rootURL.pathComponents
            guard fileComponents.count >= rootComponents.count + 2,
                  Array(fileComponents.prefix(rootComponents.count)) == rootComponents else { continue }
            let session = rootURL.appendingPathComponent(fileComponents[rootComponents.count], isDirectory: true)
            if fileManager.fileExists(atPath: session.appendingPathComponent(AudioRecorder.sessionMarkerName).path) {
                return session
            }
            for sourceName in sourceNames {
                let sourceFolder = session.appendingPathComponent(sourceName, isDirectory: true)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: sourceFolder.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return session
                }
            }
        }
        return nil
    }

    /// True for files whose type is an audio format.
    static func isAudioFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio)
    }

    /// Audio files that can be removed after a successful transcription. For
    /// recordings this covers the mixed file and the raw source tracks. Only
    /// regular audio files are returned, so the generated transcript directory
    /// (which can live inside the source folder for microphone-only recordings)
    /// and any unrelated files are always preserved.
    var deletableAudioURLs: [URL] {
        guard let inputURL else { return [] }
        let fileManager = FileManager.default
        var urls: [URL] = []
        if let sessionFolder = recordingSessionFolder {
            for sourceName in AudioRecorder.knownSourceFolderNames() {
                let sourceFolder = sessionFolder.appendingPathComponent(sourceName, isDirectory: true)
                if let contents = try? fileManager.contentsOfDirectory(
                    at: sourceFolder,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for url in contents where Self.isAudioFile(url) {
                        urls.append(url)
                    }
                }
            }
        }
        if fileManager.fileExists(atPath: inputURL.path) {
            urls.append(inputURL)
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Human-readable description of what deleting the audio removes.
    var audioDeletionPromptDetail: String {
        if let sessionFolder = recordingSessionFolder {
            return String.localizedStringWithFormat(
                String(localized: "deleteAudio.message.session"),
                sessionFolder.lastPathComponent
            )
        }
        guard let name = inputURL?.lastPathComponent else { return "" }
        return String.localizedStringWithFormat(String(localized: "deleteAudio.message.file"), name)
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    var isBusy: Bool {
        isRunning || recorder.isRecording || recorder.isFinalizingRecording
    }

    var canStart: Bool {
        inputURL != nil && !isBusy && transcriptionPrerequisiteError == nil
    }

    /// Shared by button availability and the final check before launching a
    /// helper. Files may have been removed since the settings were opened.
    var transcriptionPrerequisiteError: String? {
        guard let inputURL else { return nil }
        guard FileManager.default.isReadableFile(atPath: inputURL.path) else {
            return String(localized: "error.transcriptionInputMissing")
        }
        guard RuntimeSetup.isInstalled else { return String(localized: "runtime.required") }
        guard resolveCLI() != nil else { return String(localized: "error.whisperMLXNotInstalled") }
        guard ModelManager.isInstalled(model) else { return String(localized: "error.modelNotInstalled") }
        if diarizationEnabled {
            let path = diarizationModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty && !DiarizationModelValidation.isInstalled(at: path) {
                return String(localized: "error.diarizationModelPathInvalid")
            }
            // Do not read a Keychain secret merely to render a button.
            if path.isEmpty && !TokenStore.exists() {
                return String(localized: "error.huggingFaceTokenRequired")
            }
        }
        return nil
    }

    func selectFile(_ url: URL) {
        inputURL = url
        status = .ready
        log = ""
        audioDeleted = false
        deletionErrorMessage = nil
    }

    /// Moves the audio files of the just transcribed input to the Trash. The
    /// transcript output stays in place.
    func deleteAudioAfterTranscription() {
        let urls = deletableAudioURLs
        guard !urls.isEmpty else { return }
        let fileManager = FileManager.default
        var failed: [String] = []
        for url in urls where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        if failed.isEmpty {
            audioDeleted = true
            deletionErrorMessage = nil
            log += "\n" + String(localized: "transcription.audioDeleted") + "\n"
        } else {
            deletionErrorMessage = String.localizedStringWithFormat(
                String(localized: "error.audioDeletionFailed"),
                failed.joined(separator: ", ")
            )
            log += "\n" + (deletionErrorMessage ?? "") + "\n"
        }
    }

    /// Removes intermediate transcription artifacts that are only useful while
    /// a run is in progress: alignment block caches and resumable raw
    /// transcripts. Final transcript files are never touched.
    private func pruneIntermediateArtifacts(for outputURL: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL.appendingPathComponent(".alignment-cache", isDirectory: true))
        if let contents = try? fileManager.contentsOfDirectory(at: outputURL, includingPropertiesForKeys: nil) {
            for url in contents
            where url.pathExtension == "json" && url.lastPathComponent.contains(".rohtranskript-") {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    func start() {
        guard !isBusy, let inputURL else { return }
        if let error = transcriptionPrerequisiteError {
            status = .failed(error)
            return
        }

        let localDiarizationModel = validatedDiarizationModelPath()
        if diarizationEnabled && localDiarizationModel == nil && TokenStore.load().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = .failed(String(localized: "error.huggingFaceTokenRequired"))
            log = String(localized: "log.huggingFaceTokenRequired") + "\n"
            return
        }
        guard let executableURL = resolveCLI() else { return }

        let scoped = inputURL.startAccessingSecurityScopedResource()
        if scoped { scopedURL = inputURL }

        let runLog: TranscriptionLog
        do {
            runLog = try TranscriptionLog(inputURL: inputURL)
        } catch {
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = nil
            status = .failed("Logdatei konnte nicht angelegt werden: \(error.localizedDescription)")
            return
        }

        var arguments = [inputURL.path, "--model", model.rawValue, "--vad_method", vadMethod.rawValue]
        if let languageCode = transcriptionLanguage.whisperLanguageCode {
            arguments += ["--language", languageCode]
        }
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
        environment["PYTHONUNBUFFERED"] = "1"
        newProcess.environment = environment
        newProcess.standardOutput = outputPipe
        newProcess.standardError = outputPipe

        let outputFinished = DispatchGroup()
        outputFinished.enter()
        newProcess.terminationHandler = { [weak self] process in
            // Wait for EOF so the final traceback is saved before closing the log.
            outputFinished.wait()
            runLog.finish(exitCode: process.terminationStatus,
                          signalled: process.terminationReason == .uncaughtSignal)
            Task { @MainActor in
                guard let self else { return }
                if let error = runLog.writeError {
                    self.log.append("\nLogdatei konnte nicht vollständig geschrieben werden: \(error)\n")
                }
                self.scopedURL?.stopAccessingSecurityScopedResource()
                self.scopedURL = nil
                self.process = nil
                self.progress = nil
                if process.terminationReason == .uncaughtSignal {
                    self.status = .cancelled
                } else if process.terminationStatus == 0, let outputURL = self.outputURL {
                    self.pruneIntermediateArtifacts(for: outputURL)
                    if let inputURL = self.inputURL {
                        TranscriptionLog.prune(beside: inputURL)
                    }
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

        log = String(localized: "log.transcriptionStarted", defaultValue: "Transcription started ...") + "\n"
        audioDeleted = false
        log += "Logdatei: \(runLog.url.path)\n"
        runLog.append(Data(log.utf8))
        do {
            try newProcess.run()
            process = newProcess
            status = .running
            progress = 0
            outputPipe.fileHandleForWriting.closeFile()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer {
                    outputPipe.fileHandleForReading.closeFile()
                    outputFinished.leave()
                }
                // One reader preserves every byte, including split UTF-8 sequences.
                while true {
                    let data = outputPipe.fileHandleForReading.availableData
                    guard !data.isEmpty else { break }
                    runLog.append(data)
                    let text = String(decoding: data, as: UTF8.self)
                    Task { @MainActor in
                        guard let self else { return }
                        self.log.append(text)
                        self.updateProgress()
                    }
                }
            }
        } catch {
            outputPipe.fileHandleForWriting.closeFile()
            outputPipe.fileHandleForReading.closeFile()
            outputFinished.leave()
            runLog.append(Data("Start fehlgeschlagen: \(error.localizedDescription)\n".utf8))
            runLog.finish(exitCode: nil, signalled: false)
            scopedURL?.stopAccessingSecurityScopedResource()
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
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        // Escalate to SIGKILL if the helper ignores the polite termination.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            Task { @MainActor in
                guard let self, let process = self.process, process.isRunning else { return }
                kill(pid, SIGKILL)
            }
        }
    }

    /// Stops any running work so the app can quit without leaving an orphaned
    /// helper process behind or losing an in-progress recording.
    func shutdown() async {
        if recorder.isRecording || recorder.isFinalizingRecording {
            _ = await recorder.stop()
        }
        if let process, process.isRunning {
            process.terminate()
        }
    }

    func suggestedRecordingFolderName() -> String {
        AudioRecorder.suggestedSessionFolderName()
    }

    func startRecording(folderName: String? = nil) {
        Task {
            do {
                try await recorder.start(sessionFolderName: folderName)
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
            var message = String.localizedStringWithFormat(
                String(localized: "log.recordingSaved"),
                url.lastPathComponent
            )
            if let warning = recorder.lastFinalizeWarning, !warning.isEmpty {
                message += "\n" + warning
            }
            log = message
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

    private func validatedDiarizationModelPath() -> String? {
        let trimmedPath = diarizationModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isUsableDiarizationModelPath(trimmedPath) ? trimmedPath : nil
    }

    private static func isUsableDiarizationModelPath(_ path: String) -> Bool {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return false }

        return DiarizationModelValidation.isInstalled(at: trimmedPath)
    }
}
