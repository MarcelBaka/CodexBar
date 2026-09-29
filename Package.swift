// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "CodexTouchBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CodexTouchBar", targets: ["CodexTouchBar"]),
        .executable(name: "CodexTouchBarHook", targets: ["CodexTouchBarHook"]),
        .library(name: "CodexTouchBarCore", targets: ["CodexTouchBarCore"])
    ],
    targets: [
        .target(name: "CodexTouchBarCore"),
        .executableTarget(name: "CodexTouchBar", dependencies: ["CodexTouchBarCore"], exclude: ["Resources"]),
        .executableTarget(name: "CodexTouchBarHook", dependencies: ["CodexTouchBarCore"]),
        .testTarget(name: "CodexTouchBarCoreTests", dependencies: ["CodexTouchBarCore"])
    ]
)
