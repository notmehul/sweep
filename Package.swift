// swift-tools-version:6.2
import PackageDescription

// Command Line Tools ship the Swift Testing macro plugin outside the default search
// path, so `@Test` fails to expand without this. Xcode finds it on its own.
let testingPluginPath: [SwiftSetting] = [
    .unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"]),
]

let package = Package(
    name: "Sweep",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Sweep", targets: ["SweepApp"]),
    ],
    targets: [
        .target(name: "SweepCore"),
        .target(name: "CAttrBulk"),
        .target(
            name: "SweepStore",
            dependencies: ["SweepCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "SweepSystem", dependencies: ["SweepCore", "CAttrBulk", "SweepStore"]),
        .target(name: "SweepRules", dependencies: ["SweepCore"], resources: [.copy("Resources/rules")]),
        .target(name: "SweepAI", dependencies: ["SweepCore"]),
        .executableTarget(name: "SweepApp", dependencies: ["SweepCore", "SweepSystem", "SweepRules", "SweepStore", "SweepAI"]),
        .testTarget(
            name: "SweepCoreTests",
            dependencies: ["SweepCore"],
            swiftSettings: testingPluginPath
        ),
        .testTarget(
            name: "SweepSystemTests",
            dependencies: ["SweepSystem", "SweepCore", "SweepStore"],
            swiftSettings: testingPluginPath
        ),
        .testTarget(
            name: "SweepStoreTests",
            dependencies: ["SweepStore", "SweepCore"],
            swiftSettings: testingPluginPath
        ),
        .testTarget(
            name: "SweepRulesTests",
            dependencies: ["SweepRules", "SweepCore"],
            swiftSettings: testingPluginPath
        ),
        .testTarget(
            name: "SweepAITests",
            dependencies: ["SweepAI"],
            swiftSettings: testingPluginPath
        ),
    ]
)
