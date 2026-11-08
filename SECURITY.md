# Security policy

git-cowork runs `git` with your SSH keys and credential helpers, so security
problems matter. Thanks for reporting them responsibly.

If you sign in under Settings > Accounts, the token is stored in your login
Keychain. While git-cowork runs, it's handed to git through git's own
`credential-cache` daemon on a socket in a folder only you can read, and only
for the hosts you signed in to. Quitting the app stops the daemon.

Create SSH Key (Settings > Accounts) writes an ed25519 key to
`~/.ssh/git-cowork_<host>`, encrypted with a random passphrase that
`ssh-add --apple-use-keychain` stores in your login Keychain; the passphrase
is passed on stdin, never on a command line. The key is taken out of
ssh-agent again right away, and an existing file is never overwritten. If
adding the key to your account fails, the key and its Keychain entry are
removed. git-cowork's own network commands then run
`/usr/bin/ssh -F <config>`: that config (next to the credential socket, only
you can read it) gives the signed-in host the key with `IdentitiesOnly yes`
and includes your own `~/.ssh/config` for everything else. It isn't used if
you set `GIT_SSH_COMMAND`, `GIT_SSH` or `core.sshCommand` yourself.

### On Linux

The same design with Linux parts: tokens and SSH key passphrases are kept
in the Secret Service (GNOME Keyring, KWallet, KeePassXC). Without one,
accounts can't be saved; nothing is ever written to a plain file. The
credential-cache socket, the app's ssh config and temporary index files
live in `$XDG_RUNTIME_DIR/git-cowork` (or `~/.cache/git-cowork`), created
0700 and checked for owner and permissions, never in the shared `/tmp`.
ssh gets an app key's passphrase from git-cowork itself acting as
`SSH_ASKPASS`: it answers only ssh's own "Enter passphrase for key" prompt,
only for keys named `~/.ssh/git-cowork_<host>`, and the app's ssh config
turns off password and keyboard-interactive authentication so a server
can't send a prompt of its own. Every process is started with
`posix_spawn` and no inherited descriptors.

## Supported versions

Fixes go into the newest release and `main`. Please update before
reporting: click "Update" when git-cowork offers it, run the
[one-line install](INSTALL.md#quick-install) again, or `make update` for a
source install.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately instead:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.

You can also use this link directly:
<https://github.com/michael-smao/git-cowork/security/advisories/new>

Problems that only affect the Linux app: report them privately in this
fork instead, <https://github.com/hanneseilers/git-cowork-linux/security/advisories/new>.

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
