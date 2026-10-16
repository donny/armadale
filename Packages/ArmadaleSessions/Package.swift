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
    ],
    targets: [
        .target(
            name: "ArmadaleSessions",
            dependencies: ["ArmadaleCore"],
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
