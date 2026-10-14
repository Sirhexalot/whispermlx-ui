import XCTest
@testable import WhisperMLX_UI

@MainActor
final class DiarizationModelValidationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("diarization-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func populate() throws {
        for name in DiarizationModelValidation.requiredFiles {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("test fixture".utf8).write(to: url)
        }
    }

    func testEmptyDirectoryIsNotInstalled() {
        XCTAssertFalse(DiarizationModelValidation.isInstalled(at: root.path))
        let manager = DiarizationModelManager()
        manager.refresh(configuredPath: root.path)
        XCTAssertEqual(manager.status, .missing)
    }

    func testCompleteFilesAreInstalled() throws {
        try populate()
        XCTAssertTrue(DiarizationModelValidation.isInstalled(at: root.path))
        let manager = DiarizationModelManager()
        manager.refresh(configuredPath: root.path)
        XCTAssertEqual(manager.status, .ready)
    }

    func testEachRequiredFileIsChecked() throws {
        for name in DiarizationModelValidation.requiredFiles {
            try populate()
            try FileManager.default.removeItem(at: root.appendingPathComponent(name))
            XCTAssertEqual(DiarizationModelValidation.missingFiles(at: root.path), [name])
            XCTAssertFalse(DiarizationModelValidation.isInstalled(at: root.path))
        }
    }

    func testZeroByteFileIsNotInstalled() throws {
        try populate()
        try Data().write(to: root.appendingPathComponent("config.yaml"))
        XCTAssertFalse(DiarizationModelValidation.isInstalled(at: root.path))
    }

    func testDirectoryInsteadOfFileIsNotInstalled() throws {
        try populate()
        let config = root.appendingPathComponent("config.yaml")
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
        XCTAssertFalse(DiarizationModelValidation.isInstalled(at: root.path))
    }

    func testEmptyPathIsNotInstalled() {
        XCTAssertFalse(DiarizationModelValidation.isInstalled(at: "  "))
        let manager = DiarizationModelManager()
        manager.refresh(configuredPath: "")
        XCTAssertEqual(manager.status, .notInstalled)
    }
}
