# Security policy

git-cowork runs `git` with your SSH keys and credential helpers, so security
problems matter. Thanks for reporting them responsibly.

## Supported versions

Fixes go into the newest release and `main`. Please update with
`make update` before reporting.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately instead:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.

You can also use this link directly:
<https://github.com/michael-smao/git-cowork/security/advisories/new>

Include what you found, how to reproduce it, and which version you use
(git-cowork › About git-cowork).

You'll get a reply within a week. Once a fix is released, the report is
published as a security advisory, crediting you unless you'd rather stay
anonymous.

## What counts

For example:
- Running commands or code from a repository's contents just by opening it
  in git-cowork (beyond git's own hooks and config, which git runs anyway).
- Task, review or comment data on `refs/cowork/main` that can trigger
  unintended actions or show misleading content to teammates.
- The app sending data anywhere other than your configured git remotes.
