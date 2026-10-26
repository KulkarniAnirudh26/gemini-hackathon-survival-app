// swift-tools-version:5.9
// Parity tests for the Swift MapPack port, run on the Mac:  cd packages/sherpa_ios/swift-tests && swift test
// They read the same map pack and Python answers (parity.json) the Kotlin tests use.
import PackageDescription

let package = Package(
    name: "MapPackTests",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MapPack", path: "Sources/MapPack"),  // symlink to ../ios/MapPack
        .testTarget(name: "MapPackParityTests", dependencies: ["MapPack"], path: "Tests"),
    ]
)
