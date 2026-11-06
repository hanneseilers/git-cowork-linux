/// Options passed to every git command the app runs.
public enum GitDefaults {
    /// `-c` overrides beat any config in the repository, so a repo someone
    /// shares with you can't use them to run commands on its own.
    public static let configArgs: [String] = [
        "-c", "core.quotepath=false",   // paths as plain UTF-8
        "-c", "color.ui=false",         // output gets parsed, not shown raw
        // core.fsmonitor names a program git runs on every `git status`. The app
        // runs status by itself (on open, on file changes), so a repo's own
        // config could otherwise run code just by being opened. It's only a
        // speed-up, so turning it off changes no results.
        "-c", "core.fsmonitor=false",
    ]
}
