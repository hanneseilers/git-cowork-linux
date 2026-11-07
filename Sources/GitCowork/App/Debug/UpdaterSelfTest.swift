import AppKit
import Foundation

// Debug builds only (see DebugSnapshot.swift).
#if DEBUG

/// Exercises the in-app updater without clicking, against any release server:
///     GITCOWORK_DEBUG_UPDATE=check|install  GITCOWORK_UPDATE_API_BASE=…  GIT_COWORK_DOWNLOAD_BASE=…
/// Run it from inside an app bundle (the updater needs one). Prints what
/// happened and quits.
@MainActor
enum UpdaterSelfTest {
    static func runIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_UPDATE"] else { return }
        Task {
            let u = Updater.shared
            print("current: \(u.current?.description ?? "none"), can update: \(u.canUpdate)")
            let ok = await u.check()
            print("check ok: \(ok), available: \(u.available?.version.description ?? "none"), error: \(u.error ?? "-")")
            if mode == "install", u.available != nil {
                await u.install()
                print("installed: \(u.installed ?? "none"), error: \(u.error ?? "-")")
            }
            exit(0)
        }
    }
}

#endif
