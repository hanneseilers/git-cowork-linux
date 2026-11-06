import AppKit

/// git comes with Apple's Command Line Tools. A macOS update sometimes removes
/// them, and then every git call fails with "xcrun: error: invalid active
/// developer path". Spot that at launch and offer Apple's installer instead.
@MainActor
enum DeveloperToolsCheck {
    static func runAtLaunch() {
        // A git from Homebrew doesn't need the tools.
        guard GitRunner.shared.gitPath == "/usr/bin/git" else { return }
        Task.detached(priority: .utility) {
            let installed = toolsInstalled()
            if !installed { await MainActor.run { askToInstall() } }
        }
    }

    /// `xcode-select -p` names the tools folder. Unlike running git, it
    /// doesn't trigger macOS's own install prompt when they're missing.
    nonisolated static func toolsInstalled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let dir = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: dir + "/usr/bin/git")
    }

    private static func askToInstall() {
        let alert = NSAlert()
        alert.messageText = L("git-cowork needs Apple's developer tools")
        alert.informativeText = L("They include git. macOS sometimes removes them during an update. Installing them is free and takes a few minutes; git-cowork works again as soon as they're done.")
        alert.addButton(withTitle: L("Install"))
        alert.addButton(withTitle: L("Not Now"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Opens Apple's installer dialog.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["--install"]
        try? p.run()
    }
}
