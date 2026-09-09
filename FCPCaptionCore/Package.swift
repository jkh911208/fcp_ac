// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FCPCaptionCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FCPCaptionCore", targets: ["FCPCaptionCore"]),
        .library(name: "FCPCaptionUI", targets: ["FCPCaptionUI"]),
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
        .target(name: "FCPCaptionUI", dependencies: ["FCPCaptionCore"]),
        .executableTarget(name: "FCPCaptionCLI", dependencies: ["FCPCaptionCore"]),
        // Renders the panel states to PNG so a design change can be looked at before it ships.
        .executableTarget(name: "PanelPreview", dependencies: ["FCPCaptionUI", "FCPCaptionCore"]),
        .testTarget(name: "FCPCaptionCoreTests", dependencies: ["FCPCaptionCore"]),
        .testTarget(name: "FCPCaptionUITests", dependencies: ["FCPCaptionUI"]),
    ]
)
