// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Discette",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure logic with no AppKit: parsing, sync, formatting. Unit tested.
        .target(name: "DiscetteCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The menu bar app: players, lyrics client, floating panels, views.
        .executableTarget(name: "Discette", dependencies: ["DiscetteCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DiscetteCoreTests", dependencies: ["DiscetteCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
