#!/bin/bash
# Installs or updates git-cowork from the newest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/michael-smao/git-cowork/main/install.sh | bash
#
# No Xcode or Swift needed. Downloading with curl (not a browser) means macOS
# doesn't quarantine the app, so it opens without a Gatekeeper warning.
#
# Optional settings (environment variables):
#   GIT_COWORK_VERSION=0.2.0       a specific release instead of the newest
#   GIT_COWORK_PREFIX=~/Applications  where the app goes (default: /Applications
#                                  if you can write there, else ~/Applications)
#   GIT_COWORK_BINDIR=~/bin        where `git cowork` is linked (default ~/.local/bin)
#   GIT_COWORK_REPO=owner/name     install from a fork
set -euo pipefail

REPO="${GIT_COWORK_REPO:-michael-smao/git-cowork}"
# For testing against a local copy of the release files.
DOWNLOADS="${GIT_COWORK_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download}"
API="${GIT_COWORK_API_BASE:-https://api.github.com/repos/$REPO}"
BINDIR="${GIT_COWORK_BINDIR:-$HOME/.local/bin}"

say() { printf '%s\n' "$*"; }
fail() { printf 'git-cowork install: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "git-cowork is a Mac app."
[ "$(uname -m)" = "arm64" ] || fail "this build needs an Apple Silicon Mac."
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge 14 ] || fail "needs macOS 14 Sonoma or newer (you have $(sw_vers -productVersion))."

# Which version: the one asked for, or the newest release.
VERSION="${GIT_COWORK_VERSION:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(curl -fsSL "$API/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$VERSION" ] || fail "couldn't find the newest release of $REPO."
fi
VERSION="${VERSION#v}"

# Where the app goes.
PREFIX="${GIT_COWORK_PREFIX:-}"
if [ -z "$PREFIX" ]; then
  if [ -w /Applications ]; then PREFIX=/Applications; else PREFIX="$HOME/Applications"; fi
fi
mkdir -p "$PREFIX"
APP="$PREFIX/git-cowork.app"

ZIP="git-cowork-$VERSION-macos-arm64.zip"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/git-cowork-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say "→ Downloading git-cowork $VERSION"
curl -fSL --progress-bar -o "$WORK/$ZIP" "$DOWNLOADS/v$VERSION/$ZIP" || fail "download failed: $DOWNLOADS/v$VERSION/$ZIP"
curl -fsSL -o "$WORK/$ZIP.sha256" "$DOWNLOADS/v$VERSION/$ZIP.sha256" || fail "checksum download failed."
(cd "$WORK" && shasum -a 256 -c "$ZIP.sha256" >/dev/null) || fail "checksum doesn't match; the download is damaged. Try again."

ditto -x -k "$WORK/$ZIP" "$WORK/unpacked"
[ -d "$WORK/unpacked/git-cowork.app" ] || fail "the download doesn't contain git-cowork.app."
codesign --verify "$WORK/unpacked/git-cowork.app" 2>/dev/null || fail "the app's signature doesn't verify."
# curl doesn't quarantine downloads; clear it anyway in case the zip came another way.
xattr -dr com.apple.quarantine "$WORK/unpacked/git-cowork.app" 2>/dev/null || true

# Swap in the new app. The old one is moved aside first, so a failed copy
# leaves the existing install in place.
if [ -d "$APP" ]; then
  say "→ Replacing $APP"
  mv "$APP" "$WORK/previous.app"
else
  say "→ Installing to $APP"
fi
if ! ditto "$WORK/unpacked/git-cowork.app" "$APP"; then
  [ -d "$WORK/previous.app" ] && mv "$WORK/previous.app" "$APP"
  fail "couldn't write $APP."
fi

# `git cowork` on the PATH.
mkdir -p "$BINDIR"
ln -sf "$APP/Contents/Helpers/git-cowork" "$BINDIR/git-cowork"

say "✓ git-cowork $VERSION installed in $APP"
say "✓ git cowork linked in $BINDIR"
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) say "  To use \`git cowork\` in Terminal, add $BINDIR to your PATH:"
     say "    echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.zshrc" ;;
esac
if ! xcode-select -p >/dev/null 2>&1; then
  say "  git-cowork needs git. Install Apple's command line tools:  xcode-select --install"
fi
if pgrep -xq GitCowork; then
  say "  git-cowork is running; quit and reopen it to use the new version."
fi
