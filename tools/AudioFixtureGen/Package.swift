// swift-tools-version: 6.2
// Audio verification fixtures for the four M2.3 human-ear checks
// (부록 A-38: sound output, waveform/ear agreement, cut-point click,
// mute). Lives in tools/ beside the other disposable generators and
// probes — NOT in the root package — so nothing here can be linked into
// GyeolCore or the app by accident.
//
// The gates live in THIS package rather than Tests/GyeolCoreTests because
// the determinism gate must run the generator itself, and a root-package
// test target cannot depend on a tools package that already depends on the
// root package (SwiftPM cycle).
import PackageDescription

let package = Package(
    name: "AudioFixtureGen",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(
            name: "AudioFixtureKit",
            dependencies: [.product(name: "GyeolCore", package: "gyeol")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "audio-fixture-gen",
            dependencies: ["AudioFixtureKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "AudioFixtureKitTests",
            dependencies: [
                "AudioFixtureKit",
                .product(name: "GyeolCore", package: "gyeol"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
