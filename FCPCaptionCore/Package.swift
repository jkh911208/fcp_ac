// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FCPCaptionCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FCPCaptionCore", targets: ["FCPCaptionCore"]),
        .executable(name: "fcpcaption-cli", targets: ["FCPCaptionCLI"]),
    ],
    dependencies: [
        // The only third-party dependency in the project. Adding a second one needs approval.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0")
    ],
    targets: [
        .target(
            name: "FCPCaptionCore",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]
        ),
        .executableTarget(name: "FCPCaptionCLI", dependencies: ["FCPCaptionCore"]),
        .testTarget(name: "FCPCaptionCoreTests", dependencies: ["FCPCaptionCore"]),
    ]
)
