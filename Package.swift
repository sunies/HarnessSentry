// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HarnessSentry",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HarnessSentry", targets: ["HarnessSentryApp"]),
        .executable(name: "HarnessSentryHook", targets: ["HarnessSentryHook"]),
        .executable(name: "HarnessSentryLabProbe", targets: ["HarnessSentryLabProbe"]),
        .executable(name: "HarnessSentrySelfTest", targets: ["HarnessSentrySelfTest"]),
        .library(name: "HarnessSentryCore", targets: ["HarnessSentryCore"]),
        .library(name: "HarnessSentryESSensor", targets: ["HarnessSentryESSensor"]),
    ],
    targets: [
        .target(
            name: "CSQLite",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "HarnessSentryCore",
            dependencies: ["CSQLite"]
        ),
        .target(
            name: "HarnessSentryESSensor",
            dependencies: ["HarnessSentryCore"],
            linkerSettings: [.linkedLibrary("EndpointSecurity")]
        ),
        .executableTarget(
            name: "HarnessSentryApp",
            dependencies: ["HarnessSentryCore", "HarnessSentryESSensor"]
        ),
        .executableTarget(
            name: "HarnessSentryHook",
            dependencies: ["HarnessSentryCore"]
        ),
        .executableTarget(
            name: "HarnessSentryLabProbe",
            dependencies: ["HarnessSentryCore"]
        ),
        .executableTarget(
            name: "HarnessSentrySelfTest",
            dependencies: ["HarnessSentryCore"]
        ),
    ]
)
