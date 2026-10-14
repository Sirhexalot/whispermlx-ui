import Foundation
import Observation

enum DiarizationModelValidation {
    static let requiredFiles = [
        "config.yaml",
        "segmentation/pytorch_model.bin",
        "embedding/pytorch_model.bin",
        "plda/plda.npz",
        "plda/xvec_transform.npz"
    ]

    static func missingFiles(at path: String) -> [String] {
        let root = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        return requiredFiles.filter { name in
            let url = root.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return true }
            return !FileManager.default.isReadableFile(atPath: url.path)
        }
    }

    static func isInstalled(at path: String) -> Bool {
        !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && missingFiles(at: path).isEmpty
    }
}

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
            guard RuntimeSetup.isInstalled, let python = RuntimeSetup.pythonURL else {
                self.errorMessage = String(localized: "error.modelRuntimeMissing")
                self.downloading = nil
                return
            }

            let process = Process()
            process.executableURL = python
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

        if DiarizationModelValidation.isInstalled(at: trimmedPath) {
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
            guard RuntimeSetup.isInstalled, let python = RuntimeSetup.pythonURL else {
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

            let process = Process()
            process.executableURL = python
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            var environment = ProcessInfo.processInfo.environment
            environment["HF_TOKEN"] = trimmedToken
            process.environment = environment
            process.arguments = [
                "-c",
                """
                import os, sys
                from huggingface_hub import snapshot_download
                snapshot_download(
                    repo_id=sys.argv[1],
                    local_dir=sys.argv[2],
                    token=os.environ["HF_TOKEN"]
                )
                """,
                repository,
                trimmedDestination
            ]

            do {
                try process.run()
                output.fileHandleForWriting.closeFile()
                // Drain while the child runs so a full pipe cannot block it.
                let diagnostic = await Task.detached {
                    var tail = Data()
                    while true {
                        let chunk = output.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        tail.append(chunk)
                        if tail.count > 16_384 { tail = Data(tail.suffix(16_384)) }
                    }
                    return String(decoding: tail, as: UTF8.self)
                }.value
                await Task.detached { process.waitUntilExit() }.value
                self.refresh(configuredPath: trimmedDestination)
                if process.terminationStatus == 0 && self.status == .ready {
                    onComplete()
                } else {
                    var message = String(localized: "error.diarizationModelDownloadFailed")
                    if process.terminationStatus == 0 {
                        message += "\n" + String(localized: "error.diarizationModelIncomplete")
                            + "\n" + DiarizationModelValidation.missingFiles(at: trimmedDestination).joined(separator: "\n")
                    } else {
                        let safeDiagnostic = diagnostic.replacingOccurrences(of: trimmedToken, with: "[REDACTED]")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        message += "\n" + String(safeDiagnostic.suffix(4000))
                    }
                    self.errorMessage = message
                }
            } catch {
                self.refresh(configuredPath: trimmedDestination)
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
