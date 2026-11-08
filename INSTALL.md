# Installing and updating git-cowork

Two ways, both without an Apple Developer account and without Gatekeeper
warnings:

- **[One line](#quick-install)**: downloads the newest release. Easiest; the
  app tells you about updates and installs them for you.
- **[From source](#install-from-source)**: builds on your Mac. For changing
  the code or following `main`.

## Quick install

Needs an Apple Silicon Mac with macOS 14 or newer, and git (Apple's command
line tools: `xcode-select --install` if `git --version` doesn't work).

```bash
curl -fsSL https://raw.githubusercontent.com/michael-smao/git-cowork/main/install.sh | bash
```

It downloads the newest release from GitHub, checks its checksum, puts
`git-cowork.app` in `/Applications` (or `~/Applications` if you can't write
there) and links the `git cowork` command into `~/.local/bin`. Running the
same line again updates. Settings for the script:

```bash
# a specific version, and only for your user
curl -fsSL https://raw.githubusercontent.com/michael-smao/git-cowork/main/install.sh | GIT_COWORK_VERSION=0.2.0 GIT_COWORK_PREFIX=~/Applications bash
```

**Updates**: once a day the app checks GitHub for a newer release. When there
is one, the status bar shows "Update to x.y.z"; click it, then **Update Now**
and **Restart**. Or use **git-cowork › Check for Updates…**. Turn the daily
check off in Settings › Updates.

Downloading with `curl` is what keeps Gatekeeper quiet: macOS quarantines
apps downloaded in a browser, and an app without a paid Apple signature then
won't open. If you downloaded the zip in a browser anyway, run
`xattr -dr com.apple.quarantine /Applications/git-cowork.app` once.

## Install from source

### Requirements

- A Mac with Apple Silicon (M1 or newer)
- macOS 14 Sonoma or newer, recent enough to get Swift 6 (see below)
- Xcode Command Line Tools with **Swift 6 or newer** (for `git`, `swift` and `make`)

Check whether you have the tools:

```bash
swift --version
```

It should say `Apple Swift version 6` or higher. If it prints "command not
found" or opens an install dialog, install them:

```bash
xcode-select --install
```

If it shows Swift 5.x, your tools are too old: update them in System
Settings › General › Software Update. If no Swift 6 update is offered, update
macOS first; the Swift 6 tools need a recent macOS 14 or newer.

The download is a few GB if you don't have the tools yet. The full Xcode app
(16 or newer) works too, but isn't needed.

### Build and install

Pick a folder for the source, for example `~/Developer`, and run:

```bash
git clone https://github.com/michael-smao/git-cowork.git
```

```bash
cd git-cowork && make install
```

This builds the app and copies it to `/Applications/git-cowork.app`. Open it
from Launchpad or Spotlight. Keep the `git-cowork` folder: you'll use it to
update.

To install only for your user (no admin rights needed):

```bash
make install PREFIX=~/Applications
```

#### Stable release or latest main?

`git clone` gives you `main`, which has the newest changes. If you'd rather
stay on tested releases, switch to the newest release tag before installing:

```bash
git checkout $(git tag --list 'v*' --sort=-v:refname | head -1) && make install
```

`make update` remembers your choice: on `main` it pulls the latest
commits, on a release it moves to the next release.

### Update a source install

From the `git-cowork` folder:

```bash
make update
```

That fetches the new version, rebuilds and reinstalls. Quit and reopen the
app to use it. If you installed with `PREFIX=~/Applications`, pass the same
`PREFIX` again.

Check which version you have: **git-cowork › About git-cowork** shows e.g.
"Version 0.1.0 (1448777)", the release number and the commit it was built
from. In the terminal, `make version` prints the same for the source folder.
See [CHANGELOG.md](CHANGELOG.md) for what changed.

Install a specific version (or go back to an older one):

```bash
git fetch --tags && git checkout v0.1.0 && make install
```

Go back to following `main`:

```bash
git checkout main && make update
```

## Open repos from the terminal

```bash
open -a git-cowork .
```

Add a short alias to `~/.zshrc`:

```bash
alias gk='open -a git-cowork'
```

Then `gk .` opens the current repo.

## Uninstall

Installed from source: `make uninstall` in the `git-cowork` folder.
Installed with the one-line script: move `git-cowork.app` to the Trash and
remove the `git cowork` link:

```bash
unlink ~/.local/bin/git-cowork
```

Settings (editor, terminal, recent repos) stay in
`~/Library/Preferences/ai.smao.git-cowork.plist`; to remove them too:

```bash
defaults delete ai.smao.git-cowork
```

Tasks and reviews live in your repositories (on `refs/cowork/main`), not in
the app, so uninstalling doesn't touch them.

## Troubleshooting

**`package '…' is using Swift tools version 6.0.0 but the installed version
is 5.x`** — your Command Line Tools are too old. See
[Requirements](#requirements) for how to update them.

**`make: command not found` or `xcrun: error: invalid active developer path`**
— the Command Line Tools are missing or were removed by a macOS update. Run
`xcode-select --install`.

**Build errors after a macOS or Xcode update** — clear the build cache and try
again: `make clean && make install`.

**"git-cowork can't be opened because Apple cannot check it"** — the app was
downloaded in a browser or sent to you. Install it with the
[one-line install](#quick-install) instead, or build it from source; neither
triggers this warning.

**`make update` says "You have local changes"** — you edited files in the
source folder. Keep them with `git stash`, or throw them away with
`git checkout .`, then run `make update` again.

**`make update` says "Not possible to fast-forward"** — your local `main` has
commits that aren't upstream. If you don't need them:
`git reset --hard origin/main && make install`.

Anything else: [open an issue](https://github.com/michael-smao/git-cowork/issues)
with the version from the About window.

## Linux

For Debian and Ubuntu, see [docs/LINUX.md](docs/LINUX.md): one-line install
(`install-linux.sh`), the `.deb`, building from source with `make install`,
and uninstalling with `make uninstall`.
