import Foundation
import GitCoworkCore
import Observation

/// Checks GitHub once a day for a newer release and installs it on request
/// with the bundled install-linux.sh (download, checksum, swap the files).
/// Only for installs made by install-linux.sh into a folder the user owns;
/// packages from apt are updated by apt. Only the check talks to the
/// network: one unauthenticated request to api.github.com.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    struct Release: Equatable {
        let version: SemanticVersion
        let page: URL?
        let notes: String
    }

    private(set) var available: Release?
    private(set) var checking = false
    private(set) var installing = false
    private(set) var installed: String?
    private(set) var error: String?

    /// This build's version; nil for development builds.
    let current: SemanticVersion? = AppVersion.build == "dev" ? nil : AppVersion.semantic

    /// "owner/name" on GitHub that publishes Linux releases.
    let repository: String = {
        if let env = ProcessInfo.processInfo.environment["GIT_COWORK_REPO"], !env.isEmpty { return env }
        if let dir = AppResources.directory,
           let r = try? String(contentsOf: dir.appendingPathComponent("REPOSITORY"), encoding: .utf8) {
            let s = r.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        return "hanneseilers/git-cowork-linux"
    }()

    private var apiBase: String {
        #if DEBUG
        if let base = ProcessInfo.processInfo.environment["GIT_COWORK_API_BASE"] { return base }
        #endif
        return "https://api.github.com/repos/\(repository)"
    }

    private var script: URL? {
        AppResources.directory.map { $0.appendingPathComponent("install-linux.sh") }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Installed with install-linux.sh into a prefix we can write to.
    var canUpdate: Bool {
        guard current != nil, script != nil else { return false }
        let prefix = installPrefix
        return FileManager.default.isWritableFile(atPath: prefix + "/bin")
    }

    /// <prefix> of <prefix>/bin/git-cowork-gtk.
    private var installPrefix: String {
        URL(fileURLWithPath: AppResources.executablePath).deletingLastPathComponent().deletingLastPathComponent().path
    }

    private var loop: Task<Void, Never>?

    func startAutomaticChecks() {
        guard canUpdate, loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                let last = UserDefaults.standard.double(forKey: Prefs.Key.lastUpdateCheck)
                if Prefs.checkForUpdates, Date().timeIntervalSince1970 - last > 24 * 3600 {
                    await self?.check()
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    @discardableResult
    func check() async -> Bool {
        guard let current, !checking else { return false }
        checking = true
        defer { checking = false }
        guard let url = URL(string: "\(apiBase)/releases/latest") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("git-cowork/\(current)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String, let version = SemanticVersion(tag) else {
                error = L("Couldn't read the newest release from GitHub.")
                return false
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Prefs.Key.lastUpdateCheck)
            error = nil
            available = version > current
                ? Release(version: version, page: (obj["html_url"] as? String).flatMap(URL.init(string:)), notes: obj["body"] as? String ?? "")
                : nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func checkFromMenu() {
        let parent = App.shared.activeWindow?.root
        guard canUpdate else {
            Dialogs.alert(L("Updates aren't available for this build"),
                          L("Builds made with swift run, make run or a distribution package don't update themselves. Use make update in your git-cowork folder, or your package manager."),
                          parent: parent)
            return
        }
        Task {
            guard await check() else {
                Dialogs.alert(L("Couldn't check for updates"), error ?? "", parent: parent)
                return
            }
            if let available {
                Dialogs.confirm(String(localized: "git-cowork \(available.version.description) is available"),
                                String(localized: "You have \(current?.description ?? "?"). Update now? git-cowork restarts when it's done."),
                                confirm: L("Update Now"), destructive: false, parent: parent) {
                    Task { await Updater.shared.install(restart: true) }
                }
            } else {
                Dialogs.alert(L("You're up to date"), String(localized: "git-cowork \(current?.description ?? "") is the newest version."), parent: parent)
            }
        }
    }

    func install(restart: Bool = false) async {
        guard let available, !installing, let script else { return }
        installing = true
        error = nil
        defer { installing = false }

        var env = ProcessInfo.processInfo.environment
        env["GIT_COWORK_VERSION"] = available.version.description
        env["GIT_COWORK_PREFIX"] = installPrefix
        env["GIT_COWORK_REPO"] = repository
        let result: (status: Int32, output: String) = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let r = try? Subprocess.run("/bin/bash", [script.path], environment: env, timeout: 600) else {
                    cont.resume(returning: (-1, "bash couldn't start"))
                    return
                }
                cont.resume(returning: (r.status, String(decoding: r.stdout + r.stderr, as: UTF8.self)))
            }
        }
        guard result.status == 0 else {
            let lines = result.output.split(separator: "\n").suffix(3).joined(separator: "\n")
            error = lines.isEmpty ? L("The update didn't install.") : lines
            return
        }
        installed = available.version.description
        self.available = nil
        if restart { relaunch() }
    }

    /// Starts the updated binary and quits this one.
    func relaunch() {
        let exe = installPrefix + "/bin/git-cowork-gtk"
        let open = App.shared.windows.flatMap { $0.openRepoPaths }
        AppKitSpawn.detached("/bin/sh", ["-c", "sleep 1; exec \"$0\" \"$@\"", exe] + open)
        App.shared.quit()
    }
}

import AppKit
enum AppKitSpawn {
    static func detached(_ path: String, _ args: [String]) { NSWorkspace.spawnDetached(path, args) }
}

/// "Update to x.y.z" in the status bar.
@MainActor
final class UpdateBadge {
    let root = Box.h(4)
    init() {
        let button = Button(nil, "flat", "suggested-action")
        root.append(button)
        root.track {
            let u = Updater.shared
            if u.installing {
                button.setLabel(L("Installing…"))
                button.visible = true
                button.sensitive = false
            } else if let a = u.available {
                button.setLabel(String(localized: "Update to \(a.version.description)"))
                button.visible = true
                button.sensitive = true
            } else if let v = u.installed {
                button.setLabel(String(localized: "Restart to use \(v)"))
                button.visible = true
                button.sensitive = true
            } else {
                button.visible = false
            }
            button.tooltip(u.error)
        }
        button.onClicked {
            let u = Updater.shared
            if u.installed != nil { u.relaunch() } else { Task { await u.install(restart: true) } }
        }
    }
}

extension AppWindow {
    /// Repository folders open in this window (to reopen after an update).
    var openRepoPaths: [String] { [] }
}
