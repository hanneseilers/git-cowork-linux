import AppKit
import Foundation
import GitCoworkCore
import Observation

/// Checks GitHub once a day for a newer release, and installs it on request
/// with the install.sh bundled in the app (download, checksum, swap the app).
/// Only the release check talks to the network: one unauthenticated request
/// to api.github.com, nothing about you or your repos.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    struct Release: Equatable {
        let version: SemanticVersion
        let page: URL?
        let notes: String
    }

    /// A release newer than this app, once found.
    private(set) var available: Release?
    private(set) var checking = false
    private(set) var installing = false
    /// Version just installed; git-cowork needs a restart to run it.
    private(set) var installed: String?
    private(set) var error: String?

    /// This app's version; nil for `swift run` builds (no bundle, no updates).
    let current: SemanticVersion? = {
        guard Bundle.main.bundlePath.hasSuffix(".app"),
              let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
        return SemanticVersion(v)
    }()

    /// "owner/name" on GitHub, from Info.plist (forks change it there).
    let repository = Bundle.main.infoDictionary?["GitCoworkRepository"] as? String ?? "michael-smao/git-cowork"

    private var apiBase: String {
        #if DEBUG
        if let base = ProcessInfo.processInfo.environment["GITCOWORK_UPDATE_API_BASE"] { return base }
        #endif
        return "https://api.github.com/repos/\(repository)"
    }

    var canUpdate: Bool { current != nil && Bundle.main.url(forResource: "install", withExtension: "sh") != nil }

    // MARK: Checking

    private var loop: Task<Void, Never>?

    /// Checks shortly after launch and then once a day, while the setting is on.
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

    /// Asks GitHub for the newest release. Returns false if the check failed.
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
                ? Release(version: version, page: (obj["html_url"] as? String).flatMap(URL.init(string:)),
                          notes: obj["body"] as? String ?? "")
                : nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Help > Check for Updates…: checks now and says what it found.
    func checkFromMenu() {
        guard canUpdate else {
            alert(L("Updates aren't available for this build"),
                  L("Builds made with swift run or make run don't update themselves. Use make update in your git-cowork folder."))
            return
        }
        Task {
            guard await check() else {
                alert(L("Couldn't check for updates"), error ?? "")
                return
            }
            if let available {
                let a = NSAlert()
                a.messageText = String(localized: "git-cowork \(available.version.description) is available")
                a.informativeText = String(localized: "You have \(current?.description ?? "?"). Update now? git-cowork restarts when it's done.")
                a.addButton(withTitle: L("Update Now"))
                a.addButton(withTitle: L("Later"))
                if a.runModal() == .alertFirstButtonReturn { await install(restart: true) }
            } else {
                alert(L("You're up to date"), String(localized: "git-cowork \(current?.description ?? "") is the newest version."))
            }
        }
    }

    // MARK: Installing

    /// Runs the bundled install.sh for the available version, into the folder
    /// this app is in. With `restart`, reopens git-cowork afterwards.
    func install(restart: Bool = false) async {
        guard let available, !installing,
              let script = Bundle.main.url(forResource: "install", withExtension: "sh") else { return }
        installing = true
        error = nil
        defer { installing = false }

        var env = ProcessInfo.processInfo.environment
        env["GIT_COWORK_VERSION"] = available.version.description
        env["GIT_COWORK_PREFIX"] = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent().path
        env["GIT_COWORK_REPO"] = repository
        #if DEBUG
        for key in ["GIT_COWORK_DOWNLOAD_BASE", "GIT_COWORK_API_BASE"] {
            if let v = ProcessInfo.processInfo.environment[key] { env[key] = v }
        }
        #endif

        let result: (status: Int32, output: String) = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [script.path]
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: (-1, error.localizedDescription))
                    return
                }
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: out, as: UTF8.self)))
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

    /// Quits and opens the (now updated) app again.
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
