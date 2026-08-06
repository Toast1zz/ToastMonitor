// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ToastMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ToastMonitor",
            path: "Sources/ToastMonitor",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "ToastMonitorTests",
            dependencies: ["ToastMonitor"],
            path: "Tests/ToastMonitorTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
