// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YeelightStationMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "YeelightStation", targets: ["YeelightStation"]),
        .executable(name: "stationctl", targets: ["StationCLI"]),
        .library(name: "StationCore", targets: ["StationCore"]),
        .library(name: "StationCapture", targets: ["StationCapture"])
    ],
    targets: [
        .target(name: "StationCore", resources: [.process("Resources")]),
        .target(name: "StationCapture", dependencies: ["StationCore"]),
        .executableTarget(name: "YeelightStation", dependencies: ["StationCore", "StationCapture"], resources: [.process("Resources")]),
        .executableTarget(name: "StationCLI", dependencies: ["StationCore"]),
        .testTarget(name: "StationCoreTests", dependencies: ["StationCore"]),
        .testTarget(name: "StationCaptureTests", dependencies: ["StationCapture", "StationCore"]),
        .testTarget(name: "StationAppTests", dependencies: ["YeelightStation", "StationCore"])
    ],
    swiftLanguageModes: [.v5]
)
