# Contributing

Thanks for your interest! Bug reports, ideas and pull requests are welcome.

## Getting started

**macOS** — Apple Silicon Mac, macOS 14+, Xcode Command Line Tools with Swift 6.

```bash
make run        # debug build, run from the terminal
make test       # unit tests
make app        # build dist/git-cowork.app
```

**Linux** (Debian 13+, Ubuntu 24.04+) — Swift 6.1+ from
[swift.org](https://www.swift.org/install/linux/) or the `swift:6.1-noble`
image, plus GTK 4, libadwaita and libsecret headers (`make deps`).

```bash
make run        # debug build of the GTK app (git-cowork-gtk)
make test       # unit tests (core, CoworkKit, Linux platform layer)
make e2e        # end-to-end: keyring, ssh askpass, git cowork, the app under Xvfb
make app        # dist/linux/git-cowork-<version>-linux-<arch>(.tar.gz)
make deb        # .deb package
```

`make` picks the right rules by itself (`GNUmakefile` → the upstream
`Makefile` on macOS, `Scripts/linux/linux.mk` on Linux). See
[docs/LINUX.md](docs/LINUX.md) for how the Linux port is put together.

No Xcode project and no third-party dependencies on either platform.

## Guidelines

- **Keep it light.** No polling timers, no background work while idle. The
  app should stay at 0% CPU when nothing changes.
- **Plain git.** Every action runs the `git` CLI through `GitRunner`, so it
  shows up in the command log and respects the user's config. No libgit2.
- **Logic goes in `GitCoworkCore`** (pure Swift, no UI) and gets a test.
  UI goes in `GitCowork` (macOS) and `GitCoworkLinux` (GTK).
- **One model for both apps.** The Linux app compiles the macOS app's
  model files (`Sources/GitCowork/Git`, `Accounts`, `App/Prefs.swift`,
  `Board/BoardLogic.swift`; listed in `sharedAppSources` in
  `Package.swift`). Keep SwiftUI/AppKit out of them; where a platform
  differs, use a small `#if os(Linux)` / `#if os(macOS)` branch. A new
  model file the Linux app needs goes into `sharedAppSources`.
- **Processes on Linux** go through `Subprocess` (GitCoworkCore), not
  Foundation's `Process`, which leaks a descriptor into daemons git starts.
- **Design tokens.** Spacing, colors and fonts come from `Theme`; shared
  pieces (badges, rows, headers, sheets) live in `Components`. Heavy lists
  use AppKit and draw directly.
- Keep pull requests focused, and add a screenshot for UI changes. A
  change to shared code should build and pass `make test` on both macOS
  and Linux (CI runs both).

## Releasing (maintainers)

The version lives in `Resources/Info.plist`. To cut a release:

1. Make sure `CHANGELOG.md` has entries under `## [Unreleased]`.
2. Run `make release VERSION=x.y.z` on a clean `main`. It runs the tests,
   sets the version, dates the changelog section, commits and creates the
   tag `vx.y.z`.
3. Push: `git push origin main vx.y.z`. The Release workflow builds and
   tests, then publishes a GitHub release with the changelog notes and
   attaches `git-cowork-x.y.z-macos-arm64.zip` plus its `.sha256`. The
   one-line install and the in-app updater download that zip, so check that
   both files are on the release. The Release (Linux) workflow attaches
   `git-cowork-x.y.z-linux-x86_64.tar.gz`, `…-linux-aarch64.tar.gz`, the
   `.deb` packages and their `.sha256` files to the same release;
   `install-linux.sh` and the Linux in-app updater download the tarball.

Bump PATCH for fixes, MINOR for new features, MAJOR for breaking changes
(for example to the cowork file format on `refs/cowork/main`).

## Translations

UI text is written in English in the code; translations live in
`Resources/<lang>.lproj/Localizable.strings`, keyed by the English text.
SwiftUI literals (`Text("Commit")`) are looked up automatically. Text that
travels as a `String` goes through `Text(ui:)` or `L("…")`, and text with
values uses `String(localized: "Delete \(name)?")` (key `Delete %@?`).
Write whole sentences, not fragments glued together, so they translate.

Text that only the Linux app shows goes into
`Resources/linux/<lang>.lproj/Localizable.strings`, with the same rules
(`L("…")`, `String(localized: "… \(value) …")`; integers become `%lld`).

```bash
make check-translations   # lists text without a German translation (on Linux: the GTK app's text)
```

To add a language, copy `de.lproj`, translate the values, and add the code
to `CFBundleLocalizations` in `Resources/Info.plist`.

## Debug aids

These exist in debug builds only (`swift build`, `make run`); release builds
from `make app` / `make install` don't contain them.

Render the window to a PNG without screen-recording permission:

```bash
GITCOWORK_SNAPSHOT=/tmp/shot.png GITCOWORK_SNAPSHOT_QUIT=1 .build/debug/GitCowork /path/to/repo
```

- `GITCOWORK_SNAPSHOT_DELAY=<seconds>`
- `GITCOWORK_DEBUG_SELECT=commit:<n> | diff | commitdiff:<n>`
- `GITCOWORK_DEBUG_MODE=board | reviews` (add `:<n>` to select the nth task or review)
- `GITCOWORK_DEBUG_APPEARANCE=light | dark`
- `GITCOWORK_DEBUG_UPDATE=check | install` with `GITCOWORK_UPDATE_API_BASE=…` and
  `GIT_COWORK_DOWNLOAD_BASE=…`: runs the updater against a test release server
  and quits (run it from inside an app bundle).
- `GITCOWORK_DEBUG_LOG=1` (open the command log, e.g. to see the background fetch)

End-to-end cowork sync test against a local bare remote with two clones:

```bash
GITCOWORK_SELFTEST=/tmp/empty-dir .build/debug/GitCowork
```

The folder must be empty or one a previous self-test created; anything else
is refused, never deleted. Add `GITCOWORK_SELFTEST_SEED=1` for extra demo tasks.

You can pass several folders to `.build/debug/GitCowork a b c` to get one
tab each.

On Linux:

- `make e2e` (`Scripts/linux/e2e.sh`) is the end-to-end check: unit tests,
  Secret Service and askpass in a throwaway D-Bus session and GNOME keyring,
  an ssh login to a local sshd, `git cowork` between two clones, and the
  GTK app under Xvfb driven with xdotool (screenshots in `.build/e2e/`).
- `GIT_COWORK_NON_UNIQUE=1` runs a second, independent instance (otherwise
  folders are handed to the running app).
- `GIT_COWORK_LANG=en|de` picks the language; `GIT_COWORK_RESOURCES=<dir>`
  points at translations elsewhere.
- `.build/debug/git-cowork-gtk a b c` opens one tab per folder, as on macOS.

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
