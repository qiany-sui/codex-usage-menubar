// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexUsage",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"])
    ],
    targets: [
        .target(
            name: "UsageCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("CoreServices")
            ]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
