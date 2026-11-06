// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GitCowork",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: parsers, graph layout, host links. No UI, fully testable.
        .target(
            name: "GitCoworkCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "GitCowork",
            dependencies: ["GitCoworkCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GitCoworkCoreTests",
            dependencies: ["GitCoworkCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
