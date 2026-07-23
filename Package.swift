// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisperMLXUI",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    products: [
        .executable(name: "WhisperMLX UI", targets: ["WhisperMLXUI"])
    ],
    targets: [
        .executableTarget(
            name: "WhisperMLXUI",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/WhisperMLXUI",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
