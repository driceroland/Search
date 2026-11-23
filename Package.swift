// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Search",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Search",
            path: "Sources/Search",
            resources: [.copy("DevTools/Resources")],
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
    ]
)
