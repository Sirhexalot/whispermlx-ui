import XCTest
@testable import WhisperMLX_UI

final class RuntimeSetupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func executable(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("bin/\(name)")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testPrefersStableEntryPoint() throws {
        _ = try executable("python3.13")
        let stable = try executable("python3")
        XCTAssertEqual(RuntimeSetup.pythonURL(in: root), stable)
    }

    func testSupportsLegacyRuntime() throws {
        let legacy = try executable("python3.13")
        XCTAssertEqual(RuntimeSetup.pythonURL(in: root), legacy)
    }

    func testStableLinkSupportsFuturePythonVersion() throws {
        _ = try executable("python3.14")
        let stable = root.appendingPathComponent("bin/python3")
        try FileManager.default.createSymbolicLink(atPath: stable.path, withDestinationPath: "python3.14")
        XCTAssertEqual(RuntimeSetup.pythonURL(in: root), stable)
    }

    func testRejectsMissingOrNonExecutableRuntime() throws {
        XCTAssertNil(RuntimeSetup.pythonURL(in: root))
        try Data().write(to: root.appendingPathComponent("bin/python3"))
        XCTAssertNil(RuntimeSetup.pythonURL(in: root))
    }
}
