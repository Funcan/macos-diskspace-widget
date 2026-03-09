// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacDiskMonitor",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "MacDiskMonitor", targets: ["MacDiskMonitor"]),
    ],
    targets: [
        .executableTarget(
            name: "MacDiskMonitor",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
