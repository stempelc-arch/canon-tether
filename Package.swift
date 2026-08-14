// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "CanonTether",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "CanonTetherCore",
            targets: ["CanonTetherCore"]
        ),
        .library(
            name: "CanonTetherLib",
            targets: ["CanonTetherLib"]
        ),
        .executable(
            name: "CanonTether",
            targets: ["CanonTether"]
        )
    ],
    targets: [
        // All app logic + UI lives in a library so it can be unit-tested without linking the
        // executable's @main entry point (which crashes a headless test runner).
        // Foundation-only pure logic, unit-tested in isolation (no SwiftUI/AppKit).
        .target(
            name: "CanonTetherCore",
            path: "Sources/CanonTetherCore"
        ),
        .target(
            name: "CanonTetherLib",
            dependencies: ["CanonTetherCore"],
            path: "Sources/CanonTetherLib"
        ),
        // Thin executable: just the @main App that hosts the library's ContentView.
        .executableTarget(
            name: "CanonTether",
            dependencies: ["CanonTetherLib"],
            path: "Sources/CanonTether"
        ),
        .testTarget(
            name: "CanonTetherTests",
            dependencies: ["CanonTetherCore"],
            path: "Tests/CanonTetherTests"
        )
    ]
)
