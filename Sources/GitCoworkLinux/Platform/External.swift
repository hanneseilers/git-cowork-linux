import AppKit
import Foundation
import GitCoworkCore

/// Opening things outside the app: terminal, editor, file manager, browser,
/// clipboard. Linux counterpart of `External` in RepoActions.swift.
///
/// The terminal and editor settings hold a command (`code`, `zed`,
/// `gnome-terminal`, …). Empty, or a macOS app name from shared settings,
/// means: pick the first one installed.
enum External {
    /// Known terminals and how each is told the folder to start in.
    static let terminals: [(command: String, args: (String) -> [String])] = [
        ("x-terminal-emulator", { _ in [] }),          // Debian's alternatives entry; folder via the working directory
        ("kgx", { ["--working-directory=\($0)"] }),     // GNOME Console
        ("gnome-terminal", { ["--working-directory=\($0)"] }),
        ("ptyxis", { ["--new-window", "--working-directory=\($0)"] }),
        ("konsole", { ["--workdir", $0] }),
        ("xfce4-terminal", { ["--working-directory=\($0)"] }),
        ("tilix", { ["-w", $0] }),
        ("terminator", { ["--working-directory=\($0)"] }),
        ("alacritty", { ["--working-directory", $0] }),
        ("kitty", { ["--directory", $0] }),
        ("wezterm", { ["start", "--cwd", $0] }),
        ("foot", { ["--working-directory=\($0)"] }),
        ("ghostty", { ["--working-directory=\($0)"] }),
        ("xterm", { _ in [] }),
    ]

    static let editors = ["code", "codium", "cursor", "zed", "zeditor", "subl", "gnome-text-editor", "kate", "gedit", "mousepad", "xed"]

    /// macOS app names (from the shared default) and what they're called here.
    private static let macNames: [String: String] = [
        "visual studio code": "code", "vscodium": "codium", "cursor": "cursor", "zed": "zed",
        "sublime text": "subl", "terminal": "", "iterm": "", "ghostty": "ghostty", "warp": "",
    ]

    static func openTerminal(_ path: String) {
        let configured = command(from: Prefs.terminalApp)
        if let configured, let exe = Subprocess.which(configured.first!) {
            let known = terminals.first { $0.command == (configured.first! as NSString).lastPathComponent }
            let args = configured.count > 1 ? Array(configured.dropFirst()) : (known?.args(path) ?? [])
            NSWorkspace.spawnDetached(exe, args, currentDirectory: path)
            return
        }
        for t in terminals {
            if let exe = Subprocess.which(t.command) {
                NSWorkspace.spawnDetached(exe, t.args(path), currentDirectory: path)
                return
            }
        }
    }

    static func openEditor(_ path: String) {
        if let configured = command(from: Prefs.editorApp), let exe = Subprocess.which(configured.first!) {
            NSWorkspace.spawnDetached(exe, Array(configured.dropFirst()) + [path], currentDirectory: path)
            return
        }
        for e in editors {
            if let exe = Subprocess.which(e) {
                NSWorkspace.spawnDetached(exe, [path], currentDirectory: path)
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Opens `path` with `app` (a command); kept for parity with the macOS API.
    static func open(app: String, path: String) {
        guard let cmd = command(from: app), let exe = Subprocess.which(cmd.first!) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        NSWorkspace.spawnDetached(exe, Array(cmd.dropFirst()) + [path], currentDirectory: path)
    }

    static func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    static func browse(_ url: URL?) { if let url { NSWorkspace.shared.open(url) } }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// A setting split into program and arguments, or nil for "pick one".
    static func command(from setting: String) -> [String]? {
        let trimmed = setting.trimmingCharacters(in: .whitespaces)
        if let mapped = macNames[trimmed.lowercased()] {
            return mapped.isEmpty ? nil : [mapped]
        }
        let words = splitWords(trimmed)
        return words.isEmpty ? nil : words
    }

    /// Splits like a shell does for words and quotes (no variables, no globbing).
    static func splitWords(_ s: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var inWord = false
        var escaped = false
        for c in s {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" && quote != "'" { escaped = true; inWord = true; continue }
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
                continue
            }
            if c == "'" || c == "\"" { quote = c; inWord = true; continue }
            if c == " " || c == "\t" {
                if inWord { words.append(current); current = ""; inWord = false }
                continue
            }
            current.append(c); inWord = true
        }
        if inWord { words.append(current) }
        return words
    }

    /// First installed terminal and editor, shown as hints in Settings.
    static var detectedTerminal: String? { terminals.first { Subprocess.which($0.command) != nil }?.command }
    static var detectedEditor: String? { editors.first { Subprocess.which($0) != nil } }
}
