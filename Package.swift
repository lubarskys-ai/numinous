// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NuminousCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "NuminousCore", targets: ["NuminousCore"]),
        .executable(name: "numinous-checks", targets: ["NuminousChecks"]),
    ],
    targets: [
        .target(name: "NuminousCore"),
        // The host has only Command Line Tools (no XCTest / swift-testing module),
        // so the test suite runs as a plain executable: `swift run numinous-checks`.
        .executableTarget(
            name: "NuminousChecks",
            dependencies: ["NuminousCore"]
        ),
    ]
)
