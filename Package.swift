// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DriveDock",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DriveDock", targets: ["DriveDock"])
    ],
    targets: [
        .executableTarget(
            name: "DriveDock",
            linkerSettings: [.linkedFramework("DiskArbitration")]
        )
    ]
)
