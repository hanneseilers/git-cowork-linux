# git-cowork on Linux (Debian / Ubuntu)

This fork ports git-cowork to Linux. The Linux app is a native **GTK 4 +
libadwaita** app written in Swift. It uses the same repository model, git
actions, cowork store (tasks, board, reviews) and accounts code as the
macOS app. Only the UI and a thin platform layer are Linux-specific, so
changes from the original repository can be merged in (see
[Staying in sync with upstream](#staying-in-sync-with-upstream)).

Everything from the macOS app is there: tabs for every repo or worktree,
the commit graph with all branches and worktrees, staging per file and per
hunk, commit and amend, undo, merge/rebase banner, stashes, worktrees, the
task board, review requests, inbox and notifications, accounts with tokens
or browser sign-in, SSH keys per account, clone from your repositories,
the command log, English and German, and the `git cowork` command-line tool.

## Requirements

- Debian 13 (trixie) or newer, Ubuntu 24.04 or newer, or another distribution
  with GTK ≥ 4.12 and libadwaita ≥ 1.5
- `git` (and `openssh-client` for SSH remotes)
- For saving account tokens and SSH key passphrases: a Secret Service, i.e.
  GNOME Keyring (GNOME, Cinnamon, Xfce, …), KWallet 5.97+ (KDE) or KeePassXC
  with Secret Service integration. Without one, everything else works; adding
  an account then says that nothing could be saved. Tokens are never written
  to a plain file.
- x86_64 or aarch64

## Install

**One line, no sudo** (installs into `~/.local`):

```bash
curl -fsSL https://raw.githubusercontent.com/hanneseilers/git-cowork-linux/main/install-linux.sh | bash
```

It downloads the newest release, checks its SHA-256, and installs
`git-cowork-gtk` (the app), `git cowork` (the command-line tool), a desktop
entry and the icon. Run the same line again to update; the app also checks
once a day and offers "Update to x.y.z" in the status bar. Settings:
`GIT_COWORK_PREFIX=/usr/local` (needs sudo), `GIT_COWORK_VERSION=0.2.0`,
`GIT_COWORK_REPO=owner/name` for another fork.

Missing libraries? `sudo apt install libgtk-4-1 libadwaita-1-0 libsecret-1-0 git`.

**As a package**: download `git-cowork_<version>_amd64.deb` (or `_arm64`) from
the releases and `sudo apt install ./git-cowork_*.deb`. apt then manages
updates; the in-app updater stays off.

**From source**:

```bash
git clone https://github.com/hanneseilers/git-cowork-linux.git && cd git-cowork-linux
make deps                  # apt: GTK 4, libadwaita, libsecret, curl headers
make install               # build and install into ~/.local (PREFIX=… for another place)
make update                # later: pull, rebuild, reinstall
make uninstall
```

Building needs Swift 6.1 or newer: the toolchain from
[swift.org/install](https://www.swift.org/install/linux/) (e.g. with
`swiftly`), or the official `swift:6.1-noble` container image. The installed
binaries carry the Swift runtime, so users don't need Swift.

### Opening repositories

```bash
git-cowork-gtk .                 # this folder (a second call opens a tab in the running app)
alias gk=git-cowork-gtk          # then: gk .
```

Or start git-cowork from the app menu and drop a folder onto the window.

### `git cowork`

Works exactly as on macOS (see the README): `git cowork list --mine`,
`git cowork new "…" --assign me`, `git cowork start CW-… --worktree`, …

## Keyboard shortcuts

The macOS shortcuts with Ctrl instead of ⌘: Ctrl+O / Ctrl+Shift+O open /
clone, Ctrl+T / Ctrl+W tab, Ctrl+1/2/3 History / Board / Reviews,
Ctrl+Shift+T new task, Ctrl+Shift+R request review, Ctrl+F / Ctrl+Alt+F
filter, Ctrl+R refresh, Ctrl+Shift+F fetch, Ctrl+Shift+L / Ctrl+Shift+P
pull / push, Ctrl+Shift+B branch, Ctrl+Shift+S / Ctrl+Alt+Shift+S stash /
pop, Ctrl+0 changes, Ctrl+Enter commit, Esc close diff, Ctrl+Alt+T /
Ctrl+Alt+E terminal / editor, Ctrl+Z undo, Ctrl+Alt+← / → move a task,
Ctrl+J command log, Ctrl+, settings. Ctrl+? lists them in the app.

## Settings and data

- Settings: `~/.config/git-cowork-gtk.plist` (same keys as on macOS).
- Terminal and editor (Settings › General): a command such as `code`,
  `zed`, `gnome-terminal` or `kgx`. Empty picks the first one installed.
- Tokens and SSH key passphrases: Secret Service (`secret-tool search service git-cowork`).
- SSH keys made under Settings › Accounts: `~/.ssh/git-cowork_<host>`. The
  app's own git commands use them through a generated ssh config; ssh in
  the terminal is untouched. The key passphrase reaches ssh through the app
  itself acting as `SSH_ASKPASS`, and only for keys the app made.
- Language: follows `LANGUAGE` / `LC_ALL` / `LC_MESSAGES` / `LANG`;
  `GIT_COWORK_LANG=en` forces English.

## Development

```bash
make run                  # debug build, run from the terminal
make test                 # unit tests: core, CoworkKit, Linux platform layer
make e2e                  # end-to-end: unit tests, Secret Service, ssh askpass with a
                          # local sshd, git cowork between two clones, the app under Xvfb
make app                  # dist/linux/git-cowork-<version>-linux-<arch>(.tar.gz)
make deb                  # dist/linux/git-cowork_<version>_<arch>.deb
make check-translations   # Linux UI text without a German translation
```

`make e2e` uses what's installed and skips the rest: `dbus-run-session` and
`gnome-keyring-daemon` (keyring), `sshd` (ssh), `Xvfb` and `xdotool` (GUI).
On Ubuntu: `sudo apt install xvfb xdotool dbus-x11 gnome-keyring libsecret-tools openssh-server`.

### How the port is built

```
Package.swift            upstream package + an "#if os(Linux)" block at the end:
                         drops the SwiftUI app, adds CGtk, AppKit (shim) and GitCoworkLinux
Sources/GitCoworkCore/   shared (one Linux-only file: Subprocess.swift)
Sources/CoworkKit/       shared
Sources/GitCoworkCLI/    shared
Sources/GitCowork/       the macOS app. The Linux target compiles its model files
                         (Git/*, Accounts/*, App/Prefs.swift, Board/BoardLogic.swift)
                         unchanged, listed in `sharedAppSources` in Package.swift
Sources/CGtk/            module map for GTK 4, libadwaita, libsecret + small C helpers
Sources/LinuxShims/AppKit/
                         the few AppKit calls the shared model makes (NSApp.isActive,
                         NSWorkspace.open, NSPasteboard), answered by the GTK app
Sources/GitCoworkLinux/
  Platform/              main loop integration, localization (.strings), inotify file
                         watcher, Secret Service, notifications, terminal/editor launch,
                         SSH keys + askpass
  Gtk/                   a thin Swift layer over the GTK C API: widgets, signals as
                         closures, Observation-driven re-rendering, dialogs, Cairo/Pango
  UI/                    app, window and tabs, toolbar, sidebar, history graph, inspector,
                         diff, board, reviews, inbox, settings, accounts, clone
Resources/linux/         icon (SVG), desktop entry, AppStream data, Linux-only German text
Scripts/linux/           build, install, .deb, e2e, translations check, upstream sync
GNUmakefile              GNU make reads it first: Linux → Scripts/linux/linux.mk,
                         macOS → the upstream Makefile (unchanged)
install-linux.sh         one-line installer for release builds
```

Notes on decisions:

- **GTK 4 + libadwaita, no bindings library.** The app talks to the C API
  through a module map, like the macOS app uses AppKit directly. No
  third-party dependencies, and nothing that breaks with a bindings
  library's next release.
- **Swift concurrency on GTK's main loop.** libdispatch's main queue is
  hooked into the GLib loop through its eventfd, so `@MainActor` code and
  GTK share one thread with no polling (0% CPU when idle).
- **Processes.** Foundation's `Process` on Linux leaks a descriptor into
  daemons that git starts (the `credential-cache` helper, ssh
  ControlMaster) and then waits for them, up to 15 minutes. All git calls on
  Linux go through `Subprocess` (posix_spawn, every descriptor above stderr
  closed in the child). This also fixes the `git cowork` tool on Linux.
- **File watching** uses inotify, one watch per folder, skipping folders git
  ignores (node_modules, build output) and the object store.
- **No plain-text secrets.** Without a Secret Service, accounts can't be
  saved. The app never falls back to a file.

## Staying in sync with upstream

The original repository is
[michael-smao/git-cowork](https://github.com/michael-smao/git-cowork).
To bring its changes in:

```bash
make sync-upstream        # = Scripts/linux/sync-upstream.sh
```

It adds the `upstream` remote if needed, merges `upstream/main` into the
current branch, then builds and tests on Linux. The changes to upstream
files are kept small and marked with `#if os(Linux)` / `#if os(macOS)`, so
most merges are clean. Where conflicts can happen, the script prints what
to keep. When upstream adds a model file the Linux app should use, add it
to `sharedAppSources` at the end of `Package.swift`. New UI in the macOS
app has to be built again in `Sources/GitCoworkLinux/UI` by hand.

Branches in this fork: `main` follows upstream, `dev` holds the Linux port
(feature branches `linux/*` are merged into it).
