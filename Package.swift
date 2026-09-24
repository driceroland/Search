// swift-tools-version: 6.0
import PackageDescription

// The Mac app is the one target on a Mac. On Linux there is the start of a
// port instead (see PORTING.md): a shell of its own over GTK 4 and WebKitGTK,
// sharing only the files that never knew which system they were on.
#if os(macOS)
let targets: [Target] = [
    .executableTarget(
        name: "Search",
        path: "Sources/Search",
        // Same reasoning as the canvas app next door: the whole interface is
        // main-thread by nature, and Swift 6's strict isolation buys nothing
        // here but ceremony.
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
]
#else
let targets: [Target] = [
    .systemLibrary(
        name: "CWebKitGTK",
        path: "Sources/CWebKitGTK",
        pkgConfig: "webkitgtk-6.0",
        providers: [.apt(["libwebkitgtk-6.0-dev", "libgtk-4-dev"])]
    ),
    .executableTarget(
        name: "SearchLinux",
        dependencies: ["CWebKitGTK"],
        path: "Sources/SearchLinux",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]
#endif

let package = Package(
    name: "Search",
    platforms: [.macOS(.v14)],
    targets: targets
)
