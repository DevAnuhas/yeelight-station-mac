// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YeelightStationMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StationCore", targets: ["StationCore"])
    ],
    targets: [
        .target(name: "StationCore", resources: [.process("Resources")]),
        .testTarget(name: "StationCoreTests", dependencies: ["StationCore"])
    ],
    swiftLanguageModes: [.v5]
)
