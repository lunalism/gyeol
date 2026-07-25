// swift-tools-version: 6.2
// App-layer playback/render package. AVFoundation is allowed HERE and never
// in GyeolCore (PRD §5.6.5). The M2 preview switch imports this; until then
// its consumer is the M1.4 compositor probe.
import PackageDescription

let package = Package(
    name: "GyeolPlayback",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "GyeolPlayback", targets: ["GyeolPlayback"])
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "GyeolPlayback",
            dependencies: [.product(name: "GyeolCore", package: "gyeol")],
            // v5 mode: AVVideoCompositing's callback-queue model predates
            // strict concurrency; revisit when the protocol's async story
            // settles.
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
