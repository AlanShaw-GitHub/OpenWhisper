// swift-tools-version: 6.0
import PackageDescription

// Test entry points and probes compile only with `-Xswiftc -DOPENWHISPER_DIAGNOSTICS` (script/build_and_run.sh --diagnostics).

let package = Package(
    name: "OpenWhisper",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OpenWhisper", targets: ["OpenWhisper"])],
    targets: [
        .executableTarget(name: "OpenWhisper"),
        .testTarget(name: "OpenWhisperTests", dependencies: ["OpenWhisper"])
    ],
    swiftLanguageModes: [.v5]
)
