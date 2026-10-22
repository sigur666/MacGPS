// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacGPS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacGPS", targets: ["MacGPS"]),
        .executable(name: "gpsbridge", targets: ["gpsbridge"]),
        .library(name: "GPSCore", targets: ["GPSCore"]),
    ],
    targets: [
        .target(name: "GPSCore"),
        .executableTarget(name: "MacGPS", dependencies: ["GPSCore"]),
        .executableTarget(name: "gpsbridge", dependencies: ["GPSCore"]),
        .testTarget(name: "GPSCoreTests", dependencies: ["GPSCore"]),
    ],
    swiftLanguageModes: [.v5]
)
