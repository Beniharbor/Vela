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
        // Parakeet TDT speech engine (CoreML) — the fast alternative to Whisper.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.3"),
    ],
    targets: [
        // llama.cpp (prebuilt by the project's CI) — the built-in LLM runtime.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12441/llama-b12441-xcframework.zip",
            checksum: "cc9a0e7bba9e98eb3ba91bb01d975728b2faf02fe5ef9cb1e7284fe32d0055ee"
        ),
        .executableTarget(
            name: "Vela",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "WhisperKit", package: "WhisperKit"),
                // Speaker diarization for Voice Notes conversations (same package).
                .product(name: "SpeakerKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                "llama",
            ],
            path: "Sources/Vela",
            linkerSettings: [
                // llama.framework is copied into Vela.app/Contents/Frameworks by package.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
