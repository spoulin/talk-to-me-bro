// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrowSpeaker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BrowSpeaker",
            path: "Sources/BrowSpeaker",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
