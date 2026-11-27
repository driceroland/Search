// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The app runs on macOS 12 and later. The developer tools packages
// (DevToolsLite, DevToolsFull) still need macOS 14, so they are only part of
// the package when SEARCH_DEVTOOLS=1 is set: build.sh's build_devtools sets
// it, with a build folder of its own (.build-devtools) so the two never share
// a cache. A plain `swift build` or `swift test` is the app alone, on 12.
let devtools = ProcessInfo.processInfo.environment["SEARCH_DEVTOOLS"] == "1"

let package = Package(
    name: "Search",
    platforms: [SupportedPlatform.macOS(devtools ? .v14 : .v12)],
    products: [
        .executable(name: "Search", targets: ["Search"]),
    ] + (devtools ? [Product]([
        // A developer tools package: downloaded on request, never in the
        // app (build.sh devtools, DevToolsPackages.swift).
        .library(name: "DevToolsLite", type: .dynamic, targets: ["DevToolsLite"]),
        .library(name: "DevToolsFull", type: .dynamic, targets: ["DevToolsFull"]),
    ]) : []),
    targets: [
        // What Search and a developer tools package say to each other.
        .target(
            name: "SearchPluginAPI",
            path: "Sources/SearchPluginAPI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Search",
            dependencies: ["SearchPluginAPI"],
            path: "Sources/Search",
            // Same reasoning as the canvas app next door: the whole interface is
            // main-thread by nature, and Swift 6's strict isolation buys nothing
            // here but ceremony.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Test-only: keeps every window the unit tests make off the screen.
        .target(
            name: "NoWindows",
            path: "Tests/NoWindows",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "SearchTests",
            dependencies: ["Search", "NoWindows"],
            path: "Tests/SearchTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ] + (devtools ? [Target]([
        .target(
            name: "DevToolsLite",
            dependencies: ["SearchPluginAPI"],
            path: "Sources/DevToolsLite",
            // What build.sh puts in the feed for it, not code.
            exclude: ["package.json"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Developer Tools Full: the Chrome-style panels. Its Lighthouse,
        // Recorder and device toolbar are Lite's, the same sources compiled
        // into each (Sources/DevToolsShared, linked in as Shared/).
        .target(
            name: "DevToolsFull",
            dependencies: ["SearchPluginAPI"],
            path: "Sources/DevToolsFull",
            exclude: ["package.json"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]) : [])
)
