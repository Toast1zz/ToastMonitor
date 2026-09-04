// swift-tools-version:5.9
import PackageDescription

// SwiftPM has no application marketing-version field. Release versions are
// injected by scripts/build-app.sh from vMAJOR.MINOR[.PATCH] tags; untagged
// builds use the explicit development version 1.0.
let package = Package(
    name: "ToastMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ToastMonitor",
            path: "Sources/ToastMonitor",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications"),
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
