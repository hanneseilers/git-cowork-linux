import AppKit
import CGtk
import Foundation
import GitCoworkCore

/// The GTK application: windows, app-wide actions, platform hooks.
/// Counterpart of GitCoworkApp / AppDelegate on macOS.
@MainActor
final class App {
    static let shared = App()
    static let id = "dev.gitcowork.GitCowork"

    private(set) var gapp: UnsafeMutablePointer<AdwApplication>!
    private(set) var windows: [AppWindow] = []
    /// Folders from the command line or a second launch, opened by the next window.
    private var pendingFolders: [String] = []

    var gApplication: UnsafeMutablePointer<GApplication> { RP(gapp).assumingMemoryBound(to: GApplication.self) }

    func run() -> Int32 {
        var flags = G_APPLICATION_HANDLES_OPEN
        if ProcessInfo.processInfo.environment["GIT_COWORK_NON_UNIQUE"] == "1" {
            flags = GApplicationFlags(rawValue: flags.rawValue | G_APPLICATION_NON_UNIQUE.rawValue)
        }
        gapp = adw_application_new(Self.id, flags)
        g_set_application_name("git-cowork")
        Signal.on(RP(gapp), "startup") { [weak self] in self?.startup() }
        Signal.on(RP(gapp), "activate") { [weak self] in self?.activate() }
        Signal.on(RP(gapp), "shutdown") { Credentials.shared.stop() }   // no token stays in memory after quitting
        connectOpen()

        // GApplication parses argv itself; pass only the program name and
        // folders so our own flags don't confuse it.
        let args = CommandLine.arguments
        var cArgs = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        return g_application_run(gApplication, Int32(args.count), &cArgs)
    }

    // MARK: Lifecycle

    private func startup() {
        Theme.installCSS()
        _ = GitRunner.shared   // start resolving the login shell PATH early
        installPlatformHooks()
        installAppActions()
        Updater.shared.startAutomaticChecks()
    }

    private func activate() {
        if let window = windows.first(where: { $0.isActive }) ?? windows.last {
            window.present()
            openPending(in: window)
            return
        }
        let window = newWindow()
        openPending(in: window)
    }

    /// `git-cowork-gtk <folder>…`, or a second launch with folders.
    private func connectOpen() {
        let thunk: @convention(c) (RawPtr?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?, RawPtr?) -> Void = { _, files, n, _, _ in
            var paths: [String] = []
            for i in 0..<Int(n) {
                guard let file = files?[i], let c = g_file_get_path(file) else { continue }
                paths.append(String(cString: c))
                g_free(c)
            }
            MainActor.assumeIsolated { App.shared.open(paths: paths) }
        }
        g_signal_connect_data(RP(gapp), "open", unsafeBitCast(thunk, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    }

    func open(paths: [String]) {
        pendingFolders += paths.map { realPath($0) }
        let window = windows.first(where: { $0.isActive }) ?? windows.last ?? newWindow()
        window.present()
        openPending(in: window)
    }

    private func openPending(in window: AppWindow) {
        let folders = pendingFolders
        pendingFolders = []
        for f in folders { window.open(f) }
    }

    @discardableResult
    func newWindow() -> AppWindow {
        let w = AppWindow(app: self)
        windows.append(w)
        w.present()
        return w
    }

    func windowClosed(_ w: AppWindow) {
        windows.removeAll { $0 === w }
    }

    /// Whether any window has focus (drives NSApp.isActive for the shared model).
    func updateActive() {
        NSApp.isActive = windows.contains { $0.isActive }
    }

    func quit() {
        for w in windows { w.closeAll() }
        g_application_quit(gApplication)
    }

    // MARK: Hooks for the shared model (AppKit shim)

    private func installPlatformHooks() {
        NSApp.terminateHandler = { DispatchQueue.main.async { MainActor.assumeIsolated { App.shared.quit() } } }
        NSApp.isActive = true

        NSWorkspace.shared.openHandler = { url in
            let s = url.isFileURL ? "file://" + url.path : url.absoluteString
            // Only web and file links; anything else (javascript:, custom schemes) is refused.
            guard s.hasPrefix("https://") || s.hasPrefix("http://") || s.hasPrefix("file://") else { return false }
            MainActor.assumeIsolated {
                let launcher = gtk_uri_launcher_new(s)
                gtk_uri_launcher_launch(launcher, App.shared.activeWindow?.gtkWindow, nil, nil, nil)
                g_object_unref(RP(launcher!))
            }
            return true
        }
        NSWorkspace.shared.revealHandler = { urls in
            MainActor.assumeIsolated {
                for url in urls {
                    let file = g_file_new_for_path(url.path)
                    let launcher = gtk_file_launcher_new(file)
                    gtk_file_launcher_open_containing_folder(launcher, App.shared.activeWindow?.gtkWindow, nil, nil, nil)
                    g_object_unref(RP(launcher!))
                    g_object_unref(RawPtr(file!))
                }
            }
        }
        NSPasteboard.general.writer = { text in
            MainActor.assumeIsolated {
                guard let display = gdk_display_get_default() else { return }
                gdk_clipboard_set_text(gdk_display_get_clipboard(display), text)
            }
        }
        CoworkNotifier.shared.send = { [weak self] id, title, body, repo in
            guard let self else { return }
            let n = g_notification_new(title)!
            g_notification_set_body(n, body)
            gc_notification_set_target(n, "app.show-repo", repo)
            g_application_send_notification(self.gApplication, id, n)
            g_object_unref(RP(n))
        }
    }

    private func installAppActions() {
        addAction("quit") { App.shared.quit() }
        addAction("preferences") { SettingsDialog.present(parent: App.shared.activeWindow?.root) }
        addAction("new-window") { App.shared.newWindow() }
        addAction("about") { App.shared.showAbout() }
        addAction("check-updates") { Updater.shared.checkFromMenu() }

        // Notification clicks: bring the repo's tab to the front (open it if needed).
        let showRepo = g_simple_action_new("show-repo", g_variant_type_new("s"))!
        Signal.onPtr(RP(showRepo), "activate") { param in
            guard let param, let s = gc_variant_string(OpaquePointer(param)) else { return }
            App.shared.open(paths: [String(cString: s)])
        }
        g_action_map_add_action(OP(gapp), OP(showRepo))
    }

    private func addAction(_ name: String, _ fn: @escaping Action) {
        let action = g_simple_action_new(name, nil)!
        Signal.onPtr(RP(action), "activate") { _ in fn() }   // (action, parameter, data)
        g_action_map_add_action(OP(gapp), OP(action))
    }

    var activeWindow: AppWindow? { windows.first { $0.isActive } ?? windows.last }

    func showAbout() {
        let about = adw_about_dialog_new()!
        let d = OP(about)
        adw_about_dialog_set_application_name(d, "git-cowork")
        adw_about_dialog_set_application_icon(d, App.id)
        adw_about_dialog_set_version(d, AppVersion.display)
        adw_about_dialog_set_developer_name(d, "smao GmbH")
        adw_about_dialog_set_license_type(d, GTK_LICENSE_MIT_X11)
        adw_about_dialog_set_website(d, AppVersion.homepage)
        adw_about_dialog_set_issue_url(d, AppVersion.homepage + "/issues")
        adw_about_dialog_set_comments(d, L("A small, fast git client with a task board and code reviews that live inside your repo."))
        adw_dialog_present(RP(about).assumingMemoryBound(to: AdwDialog.self), activeWindow?.root.w)
    }
}

/// Version and build, from the VERSION file installed next to the
/// resources (written by the build script) or the macOS Info.plist in a checkout.
enum AppVersion {
    static let homepage = "https://github.com/michael-smao/git-cowork"

    static let version: String = {
        if let dir = AppResources.directory,
           let v = try? String(contentsOf: dir.appendingPathComponent("VERSION"), encoding: .utf8) {
            return v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let dir = AppResources.directory,
           let plist = try? String(contentsOf: dir.appendingPathComponent("Info.plist"), encoding: .utf8),
           let r = plist.range(of: "<key>CFBundleShortVersionString</key>") {
            let rest = plist[r.upperBound...]
            if let s = rest.range(of: "<string>"), let e = rest.range(of: "</string>"), s.upperBound < e.lowerBound {
                return String(rest[s.upperBound..<e.lowerBound])
            }
        }
        return "0.0.0"
    }()

    static let build: String = {
        if let dir = AppResources.directory,
           let b = try? String(contentsOf: dir.appendingPathComponent("BUILD"), encoding: .utf8) {
            return b.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "dev"
    }()

    static var display: String { "\(version) (\(build))" }
    static var semantic: SemanticVersion? { SemanticVersion(version) }
}
