// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YeelightStationMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StationCore", targets: ["StationCore"]),
        .library(name: "StationCapture", targets: ["StationCapture"])
    ],
    targets: [
        .target(name: "StationCore", resources: [.process("Resources")]),
        .target(name: "StationCapture", dependencies: ["StationCore"]),
        .testTarget(name: "StationCoreTests", dependencies: ["StationCore"]),
        .testTarget(name: "StationCaptureTests", dependencies: ["StationCapture", "StationCore"])
    ],
    swiftLanguageModes: [.v5]
)
