// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GitCowork",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GitCowork", targets: ["GitCowork"]),
        .executable(name: "git-cowork", targets: ["GitCoworkCLI"]),
    ],
    targets: [
        // Pure logic: parsers, graph layout, host links. No UI, fully testable.
        .target(
            name: "GitCoworkCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Reads, writes and syncs the shared tasks on refs/cowork/main.
        // Used by the app and by the git-cowork command-line tool.
        .target(
            name: "CoworkKit",
            dependencies: ["GitCoworkCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "GitCowork",
            dependencies: ["GitCoworkCore", "CoworkKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // `git cowork …`: tasks and reviews from the terminal, for people and agents.
        .executableTarget(
            name: "GitCoworkCLI",
            dependencies: ["GitCoworkCore", "CoworkKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CoworkKitTests",
            dependencies: ["CoworkKit", "GitCoworkCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GitCoworkCoreTests",
            dependencies: ["GitCoworkCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
