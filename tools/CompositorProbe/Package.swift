// swift-tools-version: 6.2
// Disposable M1.4 probe: does AVVideoCompositing hold real time at 1080p,
// and does render(document, time) come back bit-identical through the
// preview and export configurations (L2)? Delete freely.
import PackageDescription

let package = Package(
    name: "CompositorProbe",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(path: "../.."),
        .package(path: "../../app/Playback"),
    ],
    targets: [
        .executableTarget(
            name: "CompositorProbe",
            dependencies: [
                .product(name: "GyeolCore", package: "gyeol"),
                .product(name: "GyeolPlayback", package: "Playback"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
