import Foundation
import Observation

@MainActor
@Observable
final class ModelManager {
    var downloading: TranscriptionController.Model?
    var errorMessage: String?
    var cacheRevision = 0

    func isInstalled(_ model: TranscriptionController.Model) -> Bool {
        FileManager.default.fileExists(atPath: modelDirectory(for: model).path)
    }

    func remove(_ model: TranscriptionController.Model) {
        errorMessage = nil
        do {
            try FileManager.default.removeItem(at: modelDirectory(for: model))
            cacheRevision += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func modelDirectory(for model: TranscriptionController.Model) -> URL {
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
