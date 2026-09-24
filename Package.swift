// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "VoiceBenchCore",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [.library(name: "VoiceBenchCore", targets: ["VoiceBenchCore"])],
    targets: [
        .target(name: "VoiceBenchCore", path: "Sources/VoiceBenchCore"),
        .testTarget(name: "VoiceBenchCoreTests", dependencies: ["VoiceBenchCore"], path: "Tests/VoiceBenchCoreTests")
    ]
)
