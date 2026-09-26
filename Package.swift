// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "muesli",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MuesliCore", targets: ["MuesliCore"]),
        .library(name: "MuesliAudio", targets: ["MuesliAudio"]),
        .library(name: "MuesliTranscribe", targets: ["MuesliTranscribe"]),
        .library(name: "MuesliSummarize", targets: ["MuesliSummarize"]),
        .library(name: "MuesliActions", targets: ["MuesliActions"]),
        .executable(name: "muesli", targets: ["muesli"]),
    ],
    targets: [
        // Pure-Swift models. No Apple-framework imports beyond Foundation, so it
        // can be reused by the iPhone and Watch apps later.
        .target(name: "MuesliCore"),

        // Mic + system-audio capture (macOS only: Core Audio process taps).
        .target(name: "MuesliAudio", dependencies: ["MuesliCore"]),

        // On-device speech-to-text via Apple's SpeechAnalyzer.
        .target(name: "MuesliTranscribe", dependencies: ["MuesliCore", "MuesliAudio"]),

        // Notes generation: Apple Intelligence, Claude, or any OpenAI-compatible server.
        .target(name: "MuesliSummarize", dependencies: ["MuesliCore"]),

        // Reminders and Calendar via EventKit (macOS and iOS).
        .target(name: "MuesliActions", dependencies: ["MuesliCore"]),

        .executableTarget(
            name: "muesli",
            dependencies: ["MuesliCore", "MuesliAudio", "MuesliTranscribe", "MuesliSummarize", "MuesliActions"],
            linkerSettings: [
                // Embed usage strings so the mic / system-audio TCC prompts have
                // a description even for a bare command-line binary.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/muesli/Info.plist",
                ]),
            ]
        ),

        .testTarget(name: "MuesliCoreTests", dependencies: ["MuesliCore"]),
        .testTarget(name: "MuesliAudioTests", dependencies: ["MuesliAudio"]),
        .testTarget(name: "MuesliSummarizeTests", dependencies: ["MuesliSummarize", "MuesliCore"]),
        .testTarget(
            name: "MuesliTranscribeTests",
            dependencies: ["MuesliTranscribe", "MuesliAudio", "MuesliCore"],
            exclude: ["Fixtures"] // located via #filePath, not Bundle.module
        ),
    ]
)
