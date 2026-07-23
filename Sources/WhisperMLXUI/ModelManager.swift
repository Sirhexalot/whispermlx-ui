import Foundation
import Observation

@MainActor
@Observable
final class ModelManager {
    var downloading: TranscriptionController.Model?
    var errorMessage: String?
    var cacheRevision = 0

    func isInstalled(_ model: TranscriptionController.Model) -> Bool {
        Self.isInstalled(model)
    }

    static func isInstalled(_ model: TranscriptionController.Model) -> Bool {
        FileManager.default.fileExists(atPath: modelDirectory(for: model).path)
    }

    func remove(_ model: TranscriptionController.Model) {
        errorMessage = nil
        do {
            try FileManager.default.removeItem(at: Self.modelDirectory(for: model))
            cacheRevision += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func modelDirectory(for model: TranscriptionController.Model) -> URL {
        let cache = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        let directory = "models--" + model.repository.replacingOccurrences(of: "/", with: "--")
        return cache.appendingPathComponent(directory, isDirectory: true)
    }

    func download(_ model: TranscriptionController.Model) {
        guard downloading == nil else { return }
        downloading = model
        errorMessage = nil
        let repository = model.repository

        Task { @MainActor [weak self] in
            guard let self else { return }
            let candidates = [
                Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/python/bin/python").path,
                NSHomeDirectory() + "/.local/share/whispermlx-ui/venv/bin/python"
            ]
            guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                self.errorMessage = String(localized: "error.modelRuntimeMissing")
                self.downloading = nil
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-c", "from huggingface_hub import snapshot_download; snapshot_download(\"\(repository)\")"]
            do {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { _ in continuation.resume() }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                if process.terminationStatus != 0 {
                    self.errorMessage = String(localized: "error.modelDownloadFailed")
                }
                self.cacheRevision += 1
                self.downloading = nil
            } catch {
                self.errorMessage = error.localizedDescription
                self.downloading = nil
            }
        }
    }
}

@MainActor
@Observable
final class DiarizationModelManager {
    enum Status: Equatable {
        case notInstalled
        case ready
        case missing
    }

    var status: Status = .notInstalled
    var isDownloading = false
    var errorMessage: String?

    private let repository = "pyannote/speaker-diarization-community-1"

    func refresh(configuredPath: String) {
        let trimmedPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            status = .notInstalled
            return
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: trimmedPath, isDirectory: &isDirectory), isDirectory.boolValue {
            status = .ready
        } else {
            status = .missing
        }
    }

    func download(using token: String, destinationPath: String, onComplete: @escaping () -> Void) {
        guard !isDownloading else { return }

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            errorMessage = String(localized: "error.diarizationDownloadTokenRequired")
            return
        }

        let trimmedDestination = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else {
            errorMessage = String(localized: "error.diarizationModelPathInvalid")
            return
        }

        errorMessage = nil
        isDownloading = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            let candidates = [
                Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/python/bin/python").path,
                NSHomeDirectory() + "/.local/share/whispermlx-ui/venv/bin/python"
            ]
            guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                self.errorMessage = String(localized: "error.modelRuntimeMissing")
                self.isDownloading = false
                return
            }

            let destinationURL = URL(fileURLWithPath: trimmedDestination, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                self.errorMessage = error.localizedDescription
                self.isDownloading = false
                return
            }

            let escapedDestination = trimmedDestination
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let escapedToken = trimmedToken
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [
                "-c",
                """
                from huggingface_hub import snapshot_download
                snapshot_download(
                    repo_id="\(repository)",
                    local_dir="\(escapedDestination)",
                    local_dir_use_symlinks=False,
                    token="\(escapedToken)"
                )
                """
            ]

            do {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { _ in continuation.resume() }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                if process.terminationStatus == 0 {
                    self.status = .ready
                    onComplete()
                } else {
                    self.errorMessage = String(localized: "error.diarizationModelDownloadFailed")
                    self.refresh(configuredPath: trimmedDestination)
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }

            self.isDownloading = false
        }
    }

    func remove(at configuredPath: String) {
        errorMessage = nil
        let trimmedPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            status = .notInstalled
            return
        }

        do {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: trimmedPath, isDirectory: true))
            status = .notInstalled
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
