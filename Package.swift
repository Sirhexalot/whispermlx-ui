// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisperMLXUI",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WhisperMLX UI", targets: ["WhisperMLXUI"])
    ],
    targets: [
        .executableTarget(
            name: "WhisperMLXUI",
            path: "Sources/WhisperMLXUI",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
