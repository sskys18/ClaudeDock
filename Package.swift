// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeDock",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ClaudeDockCore",
            path: "ClaudeDock/Core"
        ),
        .executableTarget(
            name: "ClaudeDock",
            dependencies: ["ClaudeDockCore"],
            path: "ClaudeDock",
            exclude: [
                "Info.plist",
                "Core",
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
            ]
        ),
        .testTarget(
            name: "ClaudeDockCoreTests",
            dependencies: ["ClaudeDockCore"],
            path: "Tests/ClaudeDockCoreTests"
        ),
    ]
)
