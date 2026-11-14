// swift-tools-version: 6.4
import PackageDescription

/// Settings shared by every Armadale-owned target: Swift 6 strict concurrency
/// is implied by the language mode; warnings are promoted to errors so the
/// codebase stays warning-free.
let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "ArmadaleCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ArmadaleCore", targets: ["ArmadaleCore"]),
    ],
    targets: [
        .target(
            name: "ArmadaleCore",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "ArmadaleCoreTests",
            dependencies: ["ArmadaleCore"],
            // One state file per released version, written by that version
            // (scripts/state-fixtures/README.md).
            resources: [.copy("Fixtures")],
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
