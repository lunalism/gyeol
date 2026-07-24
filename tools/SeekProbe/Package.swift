// swift-tools-version: 6.2
// Disposable M1 verification tool (appendix A-29): does the frame-centre
// seek actually land on the intended frame? Delete freely.
import PackageDescription

let package = Package(
    name: "SeekProbe",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "SeekProbe",
            dependencies: [.product(name: "GyeolCore", package: "gyeol")],
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
