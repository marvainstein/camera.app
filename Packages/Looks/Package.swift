// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Looks",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Looks", targets: ["Looks"]),
    ],
    targets: [
        .target(name: "Looks", resources: [.copy("Resources/LUTs")]),
        .testTarget(name: "LooksTests", dependencies: ["Looks"], resources: [.process("Resources")]),
    ]
)
