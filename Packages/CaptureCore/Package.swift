// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaptureCore",
    // La lógica pura (CaptureSettings, ExposurePlan) también compila en macOS para `swift test`;
    // lo que toca AVFoundation de iPhone está detrás de `#if os(iOS)`.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
    ],
    targets: [
        .target(name: "CaptureCore"),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"]),
    ]
)
