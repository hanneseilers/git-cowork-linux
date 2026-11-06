<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="git-cowork icon">
</p>

<h1 align="center">git-cowork</h1>

<p align="center">
  A small, fast, native Mac git client — with a task board and code reviews that live inside your repo.<br>
  No accounts. No server. No telemetry. Just <code>git</code>.
</p>

<p align="center">
  <a href="https://github.com/michael-smao/git-cowork/actions/workflows/ci.yml"><img src="https://github.com/michael-smao/git-cowork/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-black" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

<p align="center">
  <img src="docs/images/history.webp" alt="History view: commit graph with branches, worktrees and uncommitted changes">
</p>

## Why

Most git GUIs are either heavy Electron apps or thin wrappers that hide what
git is doing. git-cowork is a native SwiftUI + AppKit app (about 8 MB) that
runs plain `git` underneath and shows you every command it runs.

It's built for how many teams work now: lots of branches and worktrees,
often several agents (Claude, Codex, …) working in parallel. You see all of
them in one graph, with their uncommitted changes, and you can hand out and
review work without leaving the repo.

- **Fast and light.** ~80 MB memory and 0% CPU when idle, measured on a repo
  with 8.7k commits and 27 worktrees.
- **Just git.** Every action is a normal git command, visible in the command
  log (⌘J). Your SSH keys, credential helpers, hooks and commit signing work
  exactly as in the terminal.
- **Always current.** Fetches every open repository in the background every
  5 minutes while the app is in front, so remote branches and ahead/behind
  are up to date before you pull. It never asks for a password; turn it off in
  Settings (⌘,) › Git.
- **Worktrees first.** Every worktree shows in the sidebar and the graph,
  with live uncommitted counts and ahead/behind.
- **Tasks and reviews in the repo.** A shared board and review requests,
  stored on a hidden git ref and synced with plain `git push`/`fetch`.
  Works with GitHub, GitLab, Gitea, Forgejo or any git server.

<p align="center">
  <img src="docs/images/board.webp" alt="Board view: tasks in Backlog, To Do, In Progress and In Review columns">
</p>

## Install

Requirements: Apple Silicon Mac, macOS 14 or newer, Xcode Command Line Tools with Swift 6
(details in [INSTALL.md](INSTALL.md#requirements)).

```bash
xcode-select --install          # skip if you already have git and swift
git clone https://github.com/michael-smao/git-cowork.git && cd git-cowork
make install                    # builds and copies git-cowork.app to /Applications
```

**Update** later from the same folder:

```bash
make update
```

The app is built on your own Mac and signed ad-hoc, so Gatekeeper doesn't
block it and no Apple Developer account is needed. (A built `.app` shared by
AirDrop or zip *does* trigger Gatekeeper — build from source instead.)

**[INSTALL.md](INSTALL.md)** has the details: installing just for your
user, staying on stable releases instead of `main`, installing a specific
version, uninstalling, and troubleshooting.

### Versions

Releases follow [Semantic Versioning](https://semver.org) and are tagged
`vX.Y.Z`; see [Releases](https://github.com/michael-smao/git-cowork/releases) and
[CHANGELOG.md](CHANGELOG.md). **About git-cowork** shows your version and
the commit it was built from, e.g. "Version 0.1.0 (1448777)".

### Open a repo from the terminal

```bash
open -a git-cowork .
```

Or add `alias gk='open -a git-cowork'` to `~/.zshrc` and run `gk .`.
If the front tab is empty it opens there, otherwise in a new tab. You can
also drop a folder onto any window.

## Features

| Area | |
|---|---|
| **Tabs** | Every repo or worktree is a tab; ⌘T opens a new one. |
| **Toolbar** | Repository and branch pickers (switch worktrees, recent repos, checkout), History / Board / Reviews, Pull ▾ (fetch all, ff-only, rebase, merge), Push ▾ (sets upstream; force-with-lease asks first), Branch, Worktree, Stash, Pop, Terminal, Editor, Inbox. |
| **Sidebar** | Local, remote, worktrees, tasks, reviews, stashes, tags and team, with counts. Branch folders (`claude/…`, `codex/…`) open by default. Filter with ⌥⌘F. |
| **Graph** | Lane-colored rows, author initials in nodes, branch badges connected to their commit, commits outside the current branch dimmed. A `// WIP` row above HEAD, plus one for every other worktree with uncommitted changes. |
| **Commit panel** | Message, author and co-authors, parents, refs, file list as path or tree. |
| **Changes panel** | Unstaged / staged / conflicts, stage per file or all, discard, commit, amend. |
| **Diff** | Hunk or split view, intra-line highlights, stage / unstage / discard single hunks. |
| **Merge / rebase** | Banner with Continue / Skip / Abort, conflicted files, "use mine / theirs". |
| **Hosts** | "Create pull/merge request" and "Open on …" for GitHub, GitLab, Gitea and Forgejo, including self-hosted. |
| **Accounts** | Optional. Sign in to GitHub or GitLab in the browser, or paste an access token (also Gitea / Forgejo), and HTTPS push and pull just work. Settings > Accounts. Tokens stay in the Keychain and only git-cowork uses them. For SSH remotes, Create SSH Key makes a key, adds it to your GitHub or GitLab account and uses it in git-cowork without touching `~/.ssh/config`. |
| **Board** | Shared tasks in Backlog / To Do / In Progress / In Review / Done, with assignee, labels, linked branch and comments. "Start Task" creates the branch. |
| **Reviews** | Review requests for a branch: reviewers, verdicts (approved / changes requested), comments, and the branch's changes. |
| **Inbox** | Tasks assigned to you, review requests, verdicts, @mentions and replies — also as macOS notifications. |

Right-click works almost everywhere: branches, commits, worktrees, files.

## How tasks and reviews work

Tasks, the backlog, review requests and comments are small Markdown files on
a hidden ref, `refs/cowork/main`, in the repository itself. They're pushed
and fetched with plain git like any other ref — no extra service, token or
account.

- **Teammates get it by opening the repo in git-cowork.** Nothing to set up.
- **Sync** runs about once a minute while the app is in front, every 3
  minutes in the background (so notifications still arrive), and when you
  switch back to it. Click "Tasks synced …" in the status bar to sync now.
  Notifications need the app to be running; there is no push server.
- **Your identity** is `git config user.email`. Repository › Edit Team… gives
  people names and @handles for mentions.
- **It never touches your work.** The ref is written with git plumbing into a
  temporary index: no checkout, no change to your branches, index or working
  tree, and it doesn't show up in `git branch -a`.
- **Readable without the app:**
  `git fetch origin refs/cowork/main` and
  `git show refs/cowork/main:tasks/<id>.md`.
- Settings (⌘,) › Cowork picks the remote to sync with and can turn automatic
  sync off.

Custom refs aren't shown in your host's web UI, so tasks are visible in
git-cowork and with plain git only.

## Keyboard shortcuts

| | |
|---|---|
| ⌘O / ⇧⌘O | Open / clone repository |
| ⌘T | New tab |
| ⌘1 / ⌘2 / ⌘3 | History / Board / Reviews |
| ⇧⌘T | New task |
| ⇧⌘R | Request review of the current branch |
| ⌘F / ⌥⌘F | Filter commits / filter branches |
| ⌘R | Refresh |
| ⇧⌘F | Fetch all |
| ⇧⌘L / ⇧⌘P | Pull / push |
| ⇧⌘B | New branch |
| ⇧⌘S / ⌥⇧⌘S | Stash / pop |
| ⌘0 | Uncommitted changes |
| ⌘↩ | Commit |
| Esc | Close the diff |
| ⌥⌘T / ⌥⌘E | Open in Terminal / editor |
| ⌘J | Command log |

Editor and terminal apps are set in Settings (⌘,).

## FAQ

**Intel Macs or Linux/Windows?** Not supported. The app targets Apple Silicon
and macOS 14+.

**Does it use AI?** No. It's a git client that happens to work well when
agents are making the commits.

**Why build from source instead of a download?** Downloads need Apple's
paid notarization to open without warnings. Building locally avoids that and
takes about a minute.

**Is my data sent anywhere?** No. The app only talks to your git remotes,
through your own `git`.

## Development

```bash
make run        # debug build, run from the terminal
make test       # unit tests (parsers, graph layout, diff, host links, cowork)
make app        # build dist/git-cowork.app
make version    # print the version
```

Builds with the Command Line Tools only; no Xcode project, no dependencies.

```
Sources/GitCoworkCore/   pure logic: parsers, graph lane layout, diff, host links,
                         cowork file format, merge and inbox (tested)
Sources/GitCowork/
  App/                   entry point, windows/tabs, menus, settings, welcome screen
  Git/                   GitRunner (process + env), RepoModel (state, refresh, file watching),
                         actions, CoworkStore (refs/cowork/main read/write/sync), notifier
  Views/                 Theme (design tokens), Components, History (NSTableView graph),
                         Diff, Inspector, Sidebar, Chrome, Sheets, Cowork (board, reviews, inbox)
Scripts/                 build-app.sh, make-icon.swift
```

How it stays light:
- No polling of the working tree. FSEvents watches the worktrees and the git
  dir; refreshes are debounced and merged.
- `GIT_OPTIONAL_LOCKS=0`, so the app's own `git status` doesn't rewrite the
  index and trigger another refresh.
- History reloads only when refs, HEAD or stashes actually change.
- Heavy lists (graph, diff) are AppKit views that draw directly.

## Contributing

Bug reports, ideas and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for guidelines and debug flags, and
[PLAN.md](PLAN.md) for the design and roadmap. Please follow the
[code of conduct](CODE_OF_CONDUCT.md), and report security problems
privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
