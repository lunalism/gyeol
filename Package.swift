// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "GyeolCore",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "GyeolCore", targets: ["GyeolCore"])
    ],
    targets: [
        .target(name: "GyeolCore"),
        .testTarget(name: "GyeolCoreTests", dependencies: ["GyeolCore"])
    ]
)
