// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisperMLXUI",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WhisperMLX UI", targets: ["WhisperMLXUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    targets: [
        .executableTarget(
            name: "WhisperMLXUI",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/WhisperMLXUI",
            // String catalogs generate the localized tables; legacy .strings
            // would otherwise produce the same output files a second time.
            exclude: ["Resources"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("InfoPlist.xcstrings")
            ]
        )
    ],
    // Keep the package consistent with SWIFT_VERSION in project.yml.
    swiftLanguageModes: [.v5]
)
