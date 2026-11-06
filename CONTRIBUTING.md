# Contributing

Thanks for your interest! Bug reports, ideas and pull requests are welcome.

## Getting started

Requirements: Apple Silicon Mac, macOS 14+, Xcode Command Line Tools.

```bash
make run        # debug build, run from the terminal
make test       # unit tests
make app        # build dist/git-cowork.app
```

No Xcode project and no third-party dependencies.

## Guidelines

- **Keep it light.** No polling timers, no background work while idle. The
  app should stay at 0% CPU when nothing changes.
- **Plain git.** Every action runs the `git` CLI through `GitRunner`, so it
  shows up in the command log and respects the user's config. No libgit2.
- **Logic goes in `GitCoworkCore`** (pure Swift, no UI) and gets a test.
  UI goes in `GitCowork`.
- **Design tokens.** Spacing, colors and fonts come from `Theme`; shared
  pieces (badges, rows, headers, sheets) live in `Components`. Heavy lists
  use AppKit and draw directly.
- Keep pull requests focused, and add a screenshot for UI changes.

## Releasing (maintainers)

The version lives in `Resources/Info.plist`. To cut a release:

1. Make sure `CHANGELOG.md` has entries under `## [Unreleased]`.
2. Run `make release VERSION=x.y.z` on a clean `main`. It runs the tests,
   sets the version, dates the changelog section, commits and creates the
   tag `vx.y.z`.
3. Push: `git push origin main vx.y.z`. The Release workflow builds, tests
   and publishes a GitHub release with the changelog notes.

Bump PATCH for fixes, MINOR for new features, MAJOR for breaking changes
(for example to the cowork file format on `refs/cowork/main`).

## Debug aids

Render the window to a PNG without screen-recording permission:

```bash
GITCOWORK_SNAPSHOT=/tmp/shot.png GITCOWORK_SNAPSHOT_QUIT=1 .build/debug/GitCowork /path/to/repo
```

- `GITCOWORK_SNAPSHOT_DELAY=<seconds>`
- `GITCOWORK_DEBUG_SELECT=commit:<n> | diff | commitdiff:<n>`
- `GITCOWORK_DEBUG_MODE=board | reviews` (add `:<n>` to select the nth task or review)
- `GITCOWORK_DEBUG_APPEARANCE=light | dark`

End-to-end cowork sync test against a local bare remote with two clones:

```bash
GITCOWORK_SELFTEST=/tmp/empty-dir .build/debug/GitCowork
```

You can pass several folders to `.build/debug/GitCowork a b c` to get one
tab each.

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
