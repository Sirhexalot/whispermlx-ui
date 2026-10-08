import XCTest
@testable import WhisperMLX_UI

/// Covers the pure path/format logic that decides which files count as
/// recording audio and which folder belongs to a recording session.
@MainActor
final class TranscriptionControllerLogicTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispermlx-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testIsAudioFileRecognizesCommonFormats() {
        XCTAssertTrue(TranscriptionController.isAudioFile(URL(fileURLWithPath: "/tmp/a.m4a")))
        XCTAssertTrue(TranscriptionController.isAudioFile(URL(fileURLWithPath: "/tmp/a.caf")))
        XCTAssertTrue(TranscriptionController.isAudioFile(URL(fileURLWithPath: "/tmp/a.wav")))
        XCTAssertTrue(TranscriptionController.isAudioFile(URL(fileURLWithPath: "/tmp/a.mp3")))
    }

    func testIsAudioFileRejectsNonAudio() {
        XCTAssertFalse(TranscriptionController.isAudioFile(URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertFalse(TranscriptionController.isAudioFile(URL(fileURLWithPath: "/tmp/a.transkript")))
        XCTAssertFalse(TranscriptionController.isAudioFile(URL(fileURLWithPath: "/tmp/a")))
    }

    func testSessionFolderFoundViaMarkerFromMixedFile() throws {
        let session = try makeSession(named: "Session A", marker: true)
        let mixed = session.appendingPathComponent("Recording.m4a")
        try Data().write(to: mixed)

        let found = TranscriptionController.sessionFolder(containing: mixed, recordingsRoots: [root])
        XCTAssertEqual(found?.standardizedFileURL, session.standardizedFileURL)
    }

    func testSessionFolderFoundViaMarkerFromSourceTrack() throws {
        let session = try makeSession(named: "Session B", marker: true)
        let source = session.appendingPathComponent(AudioRecorder.sourceFolderName, isDirectory: true)
        let track = source.appendingPathComponent("Microphone.caf")
        try Data().write(to: track)

        let found = TranscriptionController.sessionFolder(containing: track, recordingsRoots: [root])
        XCTAssertEqual(found?.standardizedFileURL, session.standardizedFileURL)
    }

    func testSessionFolderFallsBackToSourceFolderWithoutMarker() throws {
        let session = try makeSession(named: "Legacy", marker: false)
        let source = session.appendingPathComponent(AudioRecorder.sourceFolderName, isDirectory: true)
        let track = source.appendingPathComponent("Microphone.caf")
        try Data().write(to: track)

        let found = TranscriptionController.sessionFolder(containing: track, recordingsRoots: [root])
        XCTAssertEqual(found?.standardizedFileURL, session.standardizedFileURL)
    }

    func testSessionFolderNilForImportedFileOutsideRoot() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("imported-\(UUID().uuidString).m4a")
        try Data().write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertNil(TranscriptionController.sessionFolder(containing: outside, recordingsRoots: [root]))
    }

    // MARK: - Helpers

    private func makeSession(named name: String, marker: Bool) throws -> URL {
        let session = root.appendingPathComponent(name, isDirectory: true)
        let source = session.appendingPathComponent(AudioRecorder.sourceFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        if marker {
            try Data().write(to: session.appendingPathComponent(AudioRecorder.sessionMarkerName))
        }
        return session
    }
}
