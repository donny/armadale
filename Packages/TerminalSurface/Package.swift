// swift-tools-version: 6.4
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "TerminalSurface",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "TerminalSurface", targets: ["TerminalSurface"]),
    ],
    targets: [
        .target(name: "TerminalSurface", swiftSettings: strictSettings),
        .testTarget(
            name: "TerminalSurfaceTests",
            dependencies: ["TerminalSurface"],
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
