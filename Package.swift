// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vela",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Vendored (v2.4.0) with #Preview blocks stripped — the Xcode-only PreviewsMacros
        // plugin is missing from Command Line Tools and breaks `swift build`.
        .package(path: "Vendor/KeyboardShortcuts"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "Vela",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "WhisperKit", package: "WhisperKit"),
                // Speaker diarization for Voice Notes conversations (same package).
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ],
            path: "Sources/Vela"
        )
    ]
)
