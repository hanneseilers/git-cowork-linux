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

// MARK: - Linux (Debian / Ubuntu)
//
// Everything above is the upstream (macOS) package and stays untouched, so
// changes from the original repository merge cleanly. On Linux the SwiftUI /
// AppKit app can't build; it is replaced by the GTK 4 + libadwaita app in
// Sources/GitCoworkLinux. The core, CoworkKit, the CLI and the tests are shared.
#if os(Linux)
package.platforms = nil
package.targets.removeAll { $0.name == "GitCowork" }
package.products.removeAll { $0.name == "GitCowork" }

/// Files of the macOS app that hold no UI (repository model, git actions,
/// cowork store, accounts). The Linux app compiles the very same files, so
/// fixes and features made upstream reach Linux with a merge.
let sharedAppSources = [
    "GitCowork/Git/CommandLog.swift",
    "GitCowork/Git/CoworkActions.swift",
    "GitCowork/Git/CoworkEdits.swift",
    "GitCowork/Git/CoworkStore.swift",
    "GitCowork/Git/CoworkSync.swift",
    "GitCowork/Git/DiffLoader.swift",
    "GitCowork/Git/GitRunner.swift",
    "GitCowork/Git/RepoActions.swift",
    "GitCowork/Git/RepoModel.swift",
    "GitCowork/Git/RepoQueries.swift",
    "GitCowork/Git/RepoUndo.swift",
    "GitCowork/Accounts/Accounts.swift",
    "GitCowork/Accounts/OAuthApps.swift",
    "GitCowork/Accounts/RepoList.swift",
    "GitCowork/Accounts/SignIn.swift",
    "GitCowork/App/Prefs.swift",
]

package.products.append(.executable(name: "git-cowork-gtk", targets: ["GitCoworkLinux"]))
package.targets += [
    // GTK 4, libadwaita and libsecret, with a few C helpers (Sources/CGtk/shim.h).
    .systemLibrary(
        name: "CGtk",
        pkgConfig: "gtk4 libadwaita-1 libsecret-1",
        providers: [.apt(["libgtk-4-dev", "libadwaita-1-dev", "libsecret-1-dev"])]
    ),
    // The handful of AppKit calls the shared files make (NSApp.isActive,
    // NSWorkspace.open, NSPasteboard), answered by the GTK app.
    .target(
        name: "AppKit",
        path: "Sources/LinuxShims/AppKit",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "GitCoworkLinux",
        dependencies: ["GitCoworkCore", "CoworkKit", "CGtk", "AppKit"],
        path: "Sources",
        sources: ["GitCoworkLinux"] + sharedAppSources,
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "GitCoworkLinuxTests",
        dependencies: ["GitCoworkLinux", "GitCoworkCore", "CoworkKit"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]
#endif
