// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WayboundCore",
    platforms: [
        .iOS("26.0"),
    ],
    products: [
        .library(name: "WayboundCore", targets: ["WayboundCore"]),
        .executable(
            name: "waybound-lanelab",
            targets: ["waybound-lanelab"]
        ),
        .executable(
            name: "waybound-transit-verify",
            targets: ["waybound-transit-verify"]
        ),
    ],
    targets: [
        .target(
            name: "WayboundCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "waybound-lanelab",
            dependencies: ["WayboundCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "waybound-transit-verify",
            dependencies: ["WayboundCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WayboundCoreTests",
            dependencies: ["WayboundCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
