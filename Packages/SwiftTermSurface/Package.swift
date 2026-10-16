// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SwiftTermSurface",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SwiftTermSurface", targets: ["SwiftTermSurface"]),
    ],
    dependencies: [
        .package(path: "../TerminalSurface"),
        // Pinned to an exact release; bump deliberately.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.0"),
    ],
    targets: [
        .target(
            name: "SwiftTermSurface",
            dependencies: [
                "TerminalSurface",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            // Warnings-as-errors applies to this adapter only, never to SwiftTerm itself.
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .testTarget(
            name: "SwiftTermSurfaceTests",
            dependencies: ["SwiftTermSurface"],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
