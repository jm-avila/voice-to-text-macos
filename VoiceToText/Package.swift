// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceToText",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Parakeet on the Neural Engine. No tagged release has Parakeet Ultra yet: pinned to a commit.
        // No traits: ASR only, without TTS, diarization, or the text-normalization binary.
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "ee78635d23d52379117554ba72358b65a0612447", traits: []),
    ],
    targets: [
        // Rules and data logic with no SwiftUI, so tests run without the app.
        .target(name: "VoiceToTextKit", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(
            name: "VoiceToText",
            dependencies: ["VoiceToTextKit"],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "VoiceToTextKitTests", dependencies: ["VoiceToTextKit"]),
    ]
)
