// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WayboundCore",
    platforms: [
        .iOS("26.0"),
    ],
    products: [
        .library(name: "WayboundCore", targets: ["WayboundCore"]),
    ],
    targets: [
        .target(
            name: "WayboundCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WayboundCoreTests",
            dependencies: ["WayboundCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
