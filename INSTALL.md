# Installing and updating git-cowork

git-cowork is built from source on your own Mac. It takes about a minute,
needs no Apple Developer account, and the app opens without Gatekeeper
warnings.

## Requirements

- A Mac with Apple Silicon (M1 or newer)
- macOS 14 Sonoma or newer
- Xcode Command Line Tools (for `git`, `swift` and `make`)

Check whether you have the tools:

```bash
swift --version
```

If that prints "command not found" or opens an install dialog, install them:

```bash
xcode-select --install
```

The full Xcode app works too, but isn't needed.

## Install

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

### Stable release or latest main?

`git clone` gives you `main`, which has the newest changes. If you'd rather
stay on tested releases, switch to the newest release tag before installing:

```bash
git checkout $(git tag --list 'v*' --sort=-v:refname | head -1) && make install
```

`make update` remembers your choice: on `main` it pulls the latest
commits, on a release it moves to the next release.

## Update

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

```bash
make uninstall
```

Settings (editor, terminal, recent repos) stay in
`~/Library/Preferences/ai.smao.git-cowork.plist`; to remove them too:

```bash
defaults delete ai.smao.git-cowork
```

Tasks and reviews live in your repositories (on `refs/cowork/main`), not in
the app, so uninstalling doesn't touch them.

## Troubleshooting

**`make: command not found` or `xcrun: error: invalid active developer path`**
— the Command Line Tools are missing or were removed by a macOS update. Run
`xcode-select --install`.

**Build errors after a macOS or Xcode update** — clear the build cache and try
again: `make clean && make install`.

**"git-cowork can't be opened because Apple cannot check it"** — you're opening
a copy someone sent you. Apps built on your own Mac don't get this; build it
yourself with the steps above.

**`make update` says "You have local changes"** — you edited files in the
source folder. Keep them with `git stash`, or throw them away with
`git checkout .`, then run `make update` again.

**`make update` says "Not possible to fast-forward"** — your local `main` has
commits that aren't upstream. If you don't need them:
`git reset --hard origin/main && make install`.

Anything else: [open an issue](https://github.com/michael-smao/git-cowork/issues)
with the version from the About window.
