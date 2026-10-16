// swift-tools-version: 6.4
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "ArmadaleSessions",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ArmadaleSessions", targets: ["ArmadaleSessions"]),
    ],
    dependencies: [
        .package(path: "../ArmadaleCore"),
        .package(path: "../TerminalSurface"),
    ],
    targets: [
        .target(
            name: "ArmadaleSessions",
            dependencies: ["ArmadaleCore", "TerminalSurface"],
            swiftSettings: strictSettings
        ),
        // The trampoline that gives spawned children their controlling
        // terminal (docs/DESIGN.md section 7). `swift build` / `swift test`
        // put it next to the test bundle, where `HelperLocator` finds it. The
        // app builds the same source as its own `ctty-exec` target
        // (project.yml) and copies it to Contents/Helpers.
        .executableTarget(
            name: "ctty-exec",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "ArmadaleSessionsTests",
            dependencies: ["ArmadaleSessions"],
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
