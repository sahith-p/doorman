// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Doorman",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Doorman", targets: ["DoormanApp"]),
        .executable(name: "doorman-mcp", targets: ["doorman-mcp"]),
        .executable(name: "doorman-host", targets: ["doorman-host"]),
    ],
    targets: [
        .target(name: "DoormanCore"),
        .target(name: "DoormanUI", dependencies: ["DoormanCore"]),
        .executableTarget(name: "DoormanApp", dependencies: ["DoormanCore", "DoormanUI"]),
        .executableTarget(name: "doorman-mcp", dependencies: ["DoormanCore"]),
        .executableTarget(name: "doorman-host", dependencies: ["DoormanCore"]),
        // Dev only. Never copied into the app bundle: this holds the fake approver.
        .executableTarget(name: "doorman-e2e", dependencies: ["DoormanCore"]),
        // Dev only. Renders every screen to a PNG so the UI can be reviewed without Screen Recording.
        .executableTarget(name: "doorman-snapshots", dependencies: ["DoormanCore", "DoormanUI"]),
        .testTarget(name: "DoormanCoreTests", dependencies: ["DoormanCore"]),
    ]
)
