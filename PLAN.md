# git-cowork — plan

A small, fast Mac git client for a team that works mostly through agents.
It wraps the `git` CLI, shows branches and history clearly, handles worktrees
well, and adds lightweight shared tasks and review requests that sync through
git itself. No AI features, no accounts, no server.

Status: phase 1 (git client) and phase 2 (cowork: tasks, board, reviews, comments, mentions, notifications) are built — see README.md. Open source under the MIT license.

---

## 1. Goals and non-goals

Goals
- Daily git: fetch, pull, push, merge, rebase, branch, stash, stage, commit.
- Clear commit graph and branch list.
- First-class worktrees (agents run in them).
- Works the same with GitHub, GitLab, Gitea and Forgejo.
- Small shared backlog, task tracking and "please review this branch".
- Fast: idle at 0% CPU, low memory, instant start.

Non-goals
- AI anything.
- Replacing Slack, or being a full Jira.
- Host-specific features that need API tokens (at least not in v1).
- Windows or Linux (macOS on Apple Silicon only).

## 2. Tech stack

**Swift + SwiftUI for the app shell, AppKit for the heavy views.**

| Option | App size | Memory (typical) | Idle CPU | Notes |
|---|---|---|---|---|
| **Swift / SwiftUI + AppKit** (chosen) | ~5–10 MB | ~40–90 MB | 0% | Native controls, no runtime, builds with Command Line Tools only (verified on this machine: Swift 6.1, macOS 15, arm64). |
| Tauri (Rust + system WebKit) | ~10 MB | ~120–250 MB | low | Web UI is easier to style, but a web view per window and a JS bridge. Cross-platform we don't need. |
| Zed's GPUI (Rust) | ~15 MB | low | 0% | Very fast, but the API is young and changes often. Risky for a small team. |
| Electron (what GitKraken uses) | 150+ MB | 300 MB+ | high | The thing we're leaving. |

The memory numbers are typical ranges, not measurements of this app. We'll
measure once there's a build (see the performance targets in section 6).

Why native:
- The "UI library" is AppKit/SwiftUI itself: buttons, sidebars, tables, menus,
  keyboard shortcuts, dark mode and accessibility come built in. It looks like
  a Mac app (Finder, Xcode), not a generic web dashboard.
- Big lists (commit graph, diffs) use `NSTableView` with Core Graphics drawing.
  That stays smooth with tens of thousands of rows, where SwiftUI lists slow down.
- No third-party dependencies to start with. If needed later: Apple's
  `swift-markdown` for rendering task text.

Git access: **always the `git` CLI**, not libgit2. That way the app picks up each
person's config, SSH keys and agent (1Password and similar), credential helpers,
hooks, signing and LFS. It's also exactly what you'd type in a terminal, so a
command log can show it.

Build: Swift Package Manager + a `make app` script that wraps the binary into
`git-cowork.app` and ad-hoc signs it. No Xcode project needed.

## 3. Features — phase 1: git client

Layout (one window per repo, like Fork / GitKraken tabs):

```
┌───────────────┬──────────────────────────────────┬─────────────────────┐
│ WORKTREES     │ graph │ message        │ author │ │ commit / changes    │
│  main  ●2     │  ●    │ Fix login      │ anna   │ │ message, files,     │
│  agent-a  ↑3  │  │ ●  │ Add cache      │ claude │ │ diff                │
│ BRANCHES      │  ●─┘  │ Merge feat/x   │ ben    │ │                     │
│ REMOTES       │  ...                              │ [stage] [commit]    │
│ TAGS, STASHES │                                   │                     │
├───────────────┴──────────────────────────────────┴─────────────────────┤
│ command log: $ git fetch --all --prune   ✓ 0.8s                          │
└──────────────────────────────────────────────────────────────────────────┘
```

- **Repos**: open folder, recent list, clone.
- **Worktrees** (top of the sidebar): every worktree with branch, dirty count and
  ahead/behind. Click to switch the window to it. Add (new or existing branch),
  remove, prune, open in Finder / Terminal / editor. Good for watching what
  several agents are doing at once.
- **Graph**: all branches, lanes with stable colors, branch/tag badges on rows,
  "uncommitted changes" row on top, filter by message/author/sha, loads more
  on scroll.
- **Branches**: local (grouped by `feature/`, `claude/`, …), remotes, tags,
  stashes. Context menu: checkout, merge into current, rebase onto, push,
  rename, delete, create worktree, open PR/MR in browser.
- **Commits**: checkout, branch/tag here, cherry-pick, revert, reset
  (soft/mixed/hard, hard asks first), copy sha, open on host.
- **Working copy**: staged / unstaged / untracked, stage per file, discard
  (asks first), commit, amend.
- **Diff viewer**: unified, line numbers, handles big and binary files.
- **Merge/rebase in progress**: banner with Continue / Abort, list of
  conflicted files, open in editor, mark resolved.
- **Toolbar**: Fetch, Pull (default / ff-only / rebase), Push (sets upstream
  when there's none; force-with-lease asks first), Branch, Stash, Pop.
- **Command log**: every command the app runs that changes something, with
  output and timing. Errors show git's real message.
- **Hosts**: turns remote URLs into web links for GitHub, GitLab,
  Gitea/Forgejo (PR/MR page, commit, branch). Self-hosted names can be mapped
  in Settings (e.g. `git.company.com = gitlab`).
- **Live refresh**: watches the repo with FSEvents (no polling). Uses
  `--no-optional-locks` so the app's own `git status` doesn't trigger
  refreshes.

## 4. Features — phase 2: cowork (tasks, backlog, reviews)

### Where the shared data lives: inside the repo's git, on a hidden ref

Tasks are stored as small text files in git, under a ref the app manages,
`refs/cowork/main`. It's pushed and fetched like any branch, so it works on
GitHub, GitLab, Gitea and Forgejo without tokens, accounts or a server.

- Not a normal branch: it doesn't show up in branch lists, PR pickers or
  agents' `git branch` output.
- Written with git plumbing (`hash-object`, `mktree`, `commit-tree`,
  `update-ref`) into a temporary index. **It never touches anyone's working
  tree.**
- Plain text: Markdown with a small header. People can read it with
  `git show refs/cowork/main:tasks/CW-12.md`. Agents can read or create tasks
  with plain git, or a tiny `git cowork` CLI later.
- Prior art: `git-bug` stores issues in git refs the same way.

Downside: tasks aren't visible in the host's web UI, since custom refs aren't
shown there. If you'd rather browse them on the web, the alternative is an
orphan branch named `cowork`, which is visible on the web but shows up in
branch lists.

```
refs/cowork/main
├── team.md                         # optional: names, handles, emails
├── tasks/
│   ├── CW-a3f.md                   # one file per task
│   └── CW-a3f/
│       └── comments/
│           └── 2026-11-06T20-41-12Z-anna.md   # one file per comment
└── reviews/
    └── feat-login-cache.md         # one per review request
```

Task file:

```markdown
---
id: CW-a3f
title: Cache user sessions
status: doing          # backlog | todo | doing | review | done
assignee: anna@example.com
labels: [backend]
branch: feat/session-cache
created: 2026-11-06T20:40:00Z
updated: 2026-11-06T21:02:00Z
---
Sessions hit the DB on every request. Cache them for 5 minutes.
```

Sync without conflicts:
- One file per task and per comment, and IDs are random short hashes, not
  counters. Two people editing different things never touch the same file.
- If two people edit the same task while offline, the newer `updated:` wins
  for each field. Comments are only ever added, so they never conflict.
- The app fetches just this ref (one tiny request) every 30–60 s while open,
  and right after every normal fetch.

### What you get

- **Backlog and board**: columns Backlog / Todo / Doing / Review / Done, drag
  to move. Filter by assignee and label. Keyboard-first: `N` for a new task,
  arrow keys to move.
- **Task ↔ branch link**: "Start task" creates the branch (and optionally a
  worktree) named `CW-a3f-cache-sessions`. The graph shows the task id on
  that branch.
- **Review requests**: right-click a branch → "Request review" → pick
  teammates. They see it in a **Reviews** inbox with the branch diff against
  its base, can comment, and mark it *Approved* or *Changes requested*.
  Optional button: open a PR/MR on the host with the same title.
- **Mentions and notifications**: `@anna` in a task or comment sends Anna a
  macOS notification when her app next syncs. Identity is your
  `git config user.email`. Nothing to sign up for.
- **Chat**: deliberately **not** a live chat room. Comment threads on tasks
  and reviews arrive within about 30–60 s. Real-time chat needs a server,
  so for that you keep using Slack (or whatever you use).

## 5. Phase 3: open source release

- License (MIT or Apache-2.0), README, screenshots.
- Developer ID signing and notarization (Apple Developer account, $99/yr) so
  downloads open without Gatekeeper warnings. Until then, internal builds are
  ad-hoc signed and built from source with `make install`.
- GitHub Actions on macOS runners: build and test on every PR, release a zip
  and DMG on tags. Homebrew cask.
- Sparkle for auto-updates (optional).

## 6. Performance targets

Measured on an M1/M2 MacBook with a repo of ~50k commits:
- Cold start to usable window: < 300 ms.
- Idle CPU: 0% (FSEvents, no polling timers except the cowork sync).
- Memory: < 100 MB with 10k commits loaded.
- Graph scroll: no dropped frames at 120 Hz.
- First 2,000 commits on screen: < 150 ms; more load on scroll.

## 7. Code layout

```
Package.swift
Sources/GitCowork/
  App/          app entry, windows, menus, settings
  Git/          GitRunner (process, env, log), parsers, models, RepoModel
  Graph/        lane layout (pure, unit-tested), NSTableView + drawing
  Diff/         diff parser, diff view
  Worktrees/    list, add/remove sheets
  Cowork/       store on refs/cowork/main, sync, board, reviews, notifications
  Hosts/        remote URL → web links (GitHub, GitLab, Gitea/Forgejo)
Tests/          parsers, graph layout, cowork merge rules
Scripts/        build-app.sh, make-icon
```

Code style: small files, plain names, no premature abstraction, comments only
where something isn't obvious.

## 8. Decisions taken

1. **Cowork storage**: hidden ref `refs/cowork/main` (not shown in branch lists or web UIs).
2. **Minimum macOS**: 14 Sonoma.
3. **Chat**: no live chat; comment threads on tasks and reviews, synced every minute and on Fetch.
4. **Review requests**: kept in the app; the Request Review sheet can also open the host's PR/MR page.

How sync works: writes go through a temporary index and git plumbing, never the
working tree or HEAD. Sync fetches the ref (without touching FETCH_HEAD), merges
file by file with a field-level three-way merge, and pushes with `--no-verify`.
Proven by the built-in self-test (`GITCOWORK_SELFTEST=<dir>`): two clones,
concurrent edits, comments and approvals.

## 9. Build order

1. Skeleton app, GitRunner, command log, open repo.
2. Graph layout + history view (the hard part; unit-tested first).
3. Branch sidebar + actions; toolbar fetch/pull/push.
4. Working copy, diff, commit.
5. Worktrees panel.
6. Merge/rebase states, conflict handling.
7. Packaging (`make app`), dogfood internally for a week.
8. Cowork: store + sync, then board, then reviews, then notifications. (done)
9. Next: phase 3 — license, CI on GitHub Actions, optional signing once the repo goes public.
