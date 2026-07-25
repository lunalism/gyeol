// swift-tools-version: 6.2
// Disposable: generates the M2.1 GUI-walkthrough fixture (.gyeol package
// with a 24fps clip in a 30fps project, trailing space included).
import PackageDescription

let package = Package(
    name: "FixtureGen",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "FixtureGen",
            dependencies: [.product(name: "GyeolCore", package: "gyeol")],
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
