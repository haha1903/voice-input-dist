// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "VoiceInput",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/VoiceInput",
            linkerSettings: [
                // Embed Info.plist inside the Mach-O (__TEXT,__info_plist).
                // macOS TCC (permission prompts) only trusts an Info.plist
                // that is either in a real .app bundle **and** embedded here.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ])
            ]
        )
    ]
)
