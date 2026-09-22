import Foundation

/// Writes raw process output beside the source recording. Access is serialized
/// because output capture and process termination run on different queues.
final class TranscriptionLog: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var failure: String?
    private var closed = false

    var writeError: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    init(inputURL: URL) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let name = "\(inputURL.deletingPathExtension().lastPathComponent).transkription-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).log"
        url = inputURL.deletingLastPathComponent().appendingPathComponent(name)
        try Data().write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
        append(Data("Transkription gestartet: \(Date().ISO8601Format())\nAufnahme: \(inputURL.path)\n\n".utf8))
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error.localizedDescription
        }
    }

    func finish(exitCode: Int32?, signalled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let outcome = exitCode.map { "\(signalled ? "Signal" : "Exitcode"): \($0)" } ?? "Prozessstart fehlgeschlagen"
        do {
            try handle.write(contentsOf: Data("\nBeendet: \(Date().ISO8601Format())\n\(outcome)\n".utf8))
            try handle.synchronize()
        } catch {
            failure = error.localizedDescription
        }
        do {
            try handle.close()
        } catch {
            failure = error.localizedDescription
        }
        closed = true
    }
}
