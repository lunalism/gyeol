// swift-tools-version: 6.2
// Disposable M1 measurement tool. Not part of the shipping app; delete freely.
import PackageDescription

let package = Package(
    name: "TimescaleProbe",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        // GyeolCore is imported ONLY for FrameRate.ticksPerFrame — the single
        // L1 tick table. Re-typing 5005/4004/… here would defeat the point.
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "TimescaleProbe",
            dependencies: [.product(name: "GyeolCore", package: "gyeol")],
            // Swift 5 mode: this tool pokes AVFoundation from a CLI and is
            // throwaway; strict-concurrency friction buys nothing here.
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
