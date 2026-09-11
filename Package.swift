// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lidbend",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Lidbend",
            path: "Sources/Lidbend",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
