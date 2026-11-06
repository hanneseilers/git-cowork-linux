# Changelog

All notable changes to git-cowork. Versions follow
[Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`.
How to update: see [INSTALL.md](INSTALL.md#update).

## [Unreleased]

First public release.

### Git client
- Tabs for repositories and worktrees; repository and branch pickers.
- Commit graph with lane colors, author initials, branch badges and a
  `// WIP` row for every worktree with uncommitted changes.
- Sidebar with local and remote branches, worktrees (live uncommitted and
  ahead/behind counts), stashes and tags.
- Changes panel with staging per file or hunk, discard, commit and amend.
- Diff in hunk or split view with intra-line highlights.
- Pull, push, fetch, branch, stash, merge and rebase with conflict handling.
- Background fetch of every open repository every 5 minutes while the app is
  in front (Settings › Git › Fetch automatically). It never asks for
  credentials and pauses after a failed sign-in.
- Links to create pull/merge requests on GitHub, GitLab, Gitea and Forgejo.
- Settings > Accounts: sign in to GitHub or GitLab in the browser, or add an
  access token (also for Gitea and Forgejo), and HTTPS push and pull work
  without setting up git. Tokens are kept in the Keychain and used only by
  git-cowork; git in the terminal and SSH remotes are unchanged.
- Clone from your repos: with an account signed in, the Clone sheet lists
  your repositories and your organizations' or groups' (newest activity
  first), with a filter. Pick one to fill in its HTTPS URL, or double-click
  to clone it right away.
- Command log (⌘J) showing every git command the app runs.
- Undo (⌘Z) for the last commit, amend, reset, checkout or branch delete,
  run as plain git commands; not offered once you've pushed.
- The app's own git calls ignore a repository's `core.fsmonitor` setting,
  so opening a repo can't start a program named in its config.

### Cowork
- Shared task board (Backlog, To Do, In Progress, In Review, Done) with
  assignees, labels, linked branches and comments.
- Review requests with reviewers, verdicts and comments.
- Inbox and macOS notifications for assignments, reviews and @mentions.
- Everything stored on `refs/cowork/main` and synced with plain git.
