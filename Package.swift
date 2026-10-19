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
        .executableTarget(name: "SweepApp", dependencies: ["SweepCore"]),
        .testTarget(
            name: "SweepCoreTests",
            dependencies: ["SweepCore"],
            swiftSettings: testingPluginPath
        ),
    ]
)
