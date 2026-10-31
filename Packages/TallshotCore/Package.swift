// swift-tools-version: 6.0
// TallshotCore: the stitching engine and capture loop, with no UI and no system calls.
// It works on plain pixel buffers, so every part of it can be tested with generated frames.
// Apple's standard library only; no third-party dependencies.
import PackageDescription

let package = Package(
    name: "TallshotCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TallshotCore", targets: ["TallshotCore"]),
    ],
    targets: [
        .target(name: "TallshotCore"),
        .testTarget(name: "TallshotCoreTests", dependencies: ["TallshotCore"]),
        // The offscreen AppKit harness: a real NSScrollView, scrolled in code and rendered offscreen.
        .testTarget(name: "TallshotHarnessTests", dependencies: ["TallshotCore"]),
    ]
)
