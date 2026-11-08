#!/bin/bash
# Installs or updates git-cowork for Linux (Debian 13+, Ubuntu 24.04+) from the
# newest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/hanneseilers/git-cowork-linux/main/install-linux.sh | bash
#
# No Swift needed. Installs the app (git-cowork-gtk), the `git cowork` command,
# a desktop entry and the icon into ~/.local (no sudo), or another prefix.
#
# Optional settings (environment variables):
#   GIT_COWORK_VERSION=0.2.0     a specific release instead of the newest
#   GIT_COWORK_PREFIX=/usr/local where it goes (default ~/.local)
#   GIT_COWORK_REPO=owner/name   install from a fork
set -euo pipefail

REPO="${GIT_COWORK_REPO:-hanneseilers/git-cowork-linux}"
DOWNLOADS="${GIT_COWORK_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download}"
API="${GIT_COWORK_API_BASE:-https://api.github.com/repos/$REPO}"
PREFIX="${GIT_COWORK_PREFIX:-$HOME/.local}"

say() { printf '%s\n' "$*"; }
fail() { printf 'git-cowork install: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || fail "this installer is for Linux. On a Mac use install.sh."
case "$(uname -m)" in
  x86_64|amd64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) fail "no build for $(uname -m) yet. Build from source: see docs/LINUX.md." ;;
esac
for tool in curl tar sha256sum; do command -v "$tool" >/dev/null || fail "needs $tool."; done

# Libraries the app links against.
missing=()
have_lib() { ldconfig -p 2>/dev/null | grep -q "$1" || [ -e "/usr/lib/$(uname -m)-linux-gnu/$1" ] || [ -e "/usr/lib64/$1" ] || [ -e "/usr/lib/$1" ]; }
have_lib libgtk-4.so.1 || missing+=(libgtk-4-1)
have_lib libadwaita-1.so.0 || missing+=(libadwaita-1-0)
have_lib libsecret-1.so.0 || missing+=(libsecret-1-0)
have_lib libcurl.so.4 || missing+=(libcurl4)
command -v git >/dev/null || missing+=(git)
if [ ${#missing[@]} -gt 0 ]; then
  say "git-cowork needs: ${missing[*]}"
  say "  Debian/Ubuntu:  sudo apt install ${missing[*]}"
  fail "install those first, then run this again."
fi

VERSION="${GIT_COWORK_VERSION:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(curl -fsSL "$API/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$VERSION" ] || fail "couldn't find the newest release of $REPO."
fi
VERSION="${VERSION#v}"
case "$VERSION" in *[!0-9A-Za-z.+-]*|"") fail "odd version '$VERSION'." ;; esac

NAME="git-cowork-$VERSION-linux-$ARCH"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/git-cowork-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say "→ Downloading git-cowork $VERSION"
curl -fSL --progress-bar -o "$WORK/$NAME.tar.gz" "$DOWNLOADS/v$VERSION/$NAME.tar.gz" || fail "download failed: $DOWNLOADS/v$VERSION/$NAME.tar.gz"
curl -fsSL -o "$WORK/$NAME.tar.gz.sha256" "$DOWNLOADS/v$VERSION/$NAME.tar.gz.sha256" || fail "checksum download failed."
(cd "$WORK" && sha256sum -c "$NAME.tar.gz.sha256" >/dev/null) || fail "checksum doesn't match; the download is damaged. Try again."

# Refuse archives with absolute paths or ".." (nothing may land outside $WORK).
if tar -tzf "$WORK/$NAME.tar.gz" | grep -Eq '^/|(^|/)\.\.(/|$)'; then fail "the archive has unsafe paths."; fi
tar -xzf "$WORK/$NAME.tar.gz" -C "$WORK" --no-same-owner
SRC="$WORK/$NAME"
[ -x "$SRC/bin/git-cowork-gtk" ] || fail "the download doesn't contain git-cowork-gtk."

say "→ Installing into $PREFIX"
mkdir -p "$PREFIX/bin" "$PREFIX/share/applications" "$PREFIX/share/icons/hicolor/scalable/apps" "$PREFIX/share/metainfo"
# Resources first (swapped as a whole), then the binaries by rename, so a
# running app keeps working and a failed copy leaves the old install.
rm -rf "$PREFIX/share/git-cowork.new"
cp -R "$SRC/share/git-cowork" "$PREFIX/share/git-cowork.new"
rm -rf "$PREFIX/share/git-cowork.old"
[ -d "$PREFIX/share/git-cowork" ] && mv "$PREFIX/share/git-cowork" "$PREFIX/share/git-cowork.old"
mv "$PREFIX/share/git-cowork.new" "$PREFIX/share/git-cowork"
rm -rf "$PREFIX/share/git-cowork.old"
for b in git-cowork-gtk git-cowork; do
  install -m 755 "$SRC/bin/$b" "$PREFIX/bin/.$b.new"
  mv -f "$PREFIX/bin/.$b.new" "$PREFIX/bin/$b"
done
# The desktop entry runs the binary from this prefix (works without it on PATH).
sed "s|^Exec=git-cowork-gtk|Exec=$PREFIX/bin/git-cowork-gtk|" "$SRC/share/applications/dev.gitcowork.GitCowork.desktop" \
  > "$PREFIX/share/applications/dev.gitcowork.GitCowork.desktop"
cp "$SRC/share/icons/hicolor/scalable/apps/dev.gitcowork.GitCowork.svg" "$PREFIX/share/icons/hicolor/scalable/apps/"
cp "$SRC/share/metainfo/dev.gitcowork.GitCowork.metainfo.xml" "$PREFIX/share/metainfo/"
command -v update-desktop-database >/dev/null && update-desktop-database -q "$PREFIX/share/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$PREFIX/share/icons/hicolor" 2>/dev/null || true

say "✓ git-cowork $VERSION installed: $PREFIX/bin/git-cowork-gtk"
say "✓ git cowork installed: $PREFIX/bin/git-cowork"
case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) say "  Add $PREFIX/bin to your PATH to use git-cowork-gtk and \`git cowork\` in a terminal:"
     say "    echo 'export PATH=\"$PREFIX/bin:\$PATH\"' >> ~/.bashrc" ;;
esac
if pgrep -x git-cowork-gtk >/dev/null 2>&1; then
  say "  git-cowork is running; quit and reopen it to use the new version."
fi
