import Foundation
import Observation

@MainActor
@Observable
final class RuntimeSetup {
    static let version = "whispermlx=3.14.0 mlx=0.32.3 mlx-metal=0.32.3"
    private(set) var isInstalling = false
    private(set) var message = ""
    private(set) var isReady = false

    init() { refresh() }

    func refresh() {
        isReady = Self.isInstalled
    }

    static var isInstalled: Bool {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/whispermlx-ui/runtime")
        let receipt = try? String(contentsOf: root.appendingPathComponent("runtime-version"), encoding: .utf8)
        return receipt?.trimmingCharacters(in: .whitespacesAndNewlines) == version &&
            FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("bin/python3.13").path)
    }

    func install() {
        guard !isInstalling else { return }
        let installer = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/setup-runtime")
        guard FileManager.default.isExecutableFile(atPath: installer.path) else {
            message = "Runtime installer is missing from the app."
            return
        }
        isInstalling = true
        message = String(localized: "runtime.installing")
        Task {
            let process = Process()
            let output = Pipe()
            process.executableURL = installer
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                output.fileHandleForWriting.closeFile()
                let text = await Task.detached {
                    String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                }.value
                await Task.detached { process.waitUntilExit() }.value
                refresh()
                message = process.terminationStatus == 0 && isReady
                    ? String(localized: "runtime.ready")
                    : String(localized: "runtime.failed") + "\n" + text.suffix(1500)
            } catch {
                message = error.localizedDescription
            }
            isInstalling = false
        }
    }
}
