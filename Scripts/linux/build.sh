#!/bin/bash
# Builds git-cowork for Linux: release binaries with the Swift runtime linked
# in (the target machine needs GTK 4, libadwaita, libsecret and git, not Swift),
# and lays out an install tree:
#
#   dist/linux/git-cowork-<version>-linux-<arch>/
#     bin/git-cowork-gtk            the app
#     bin/git-cowork                the `git cowork` command
#     share/git-cowork/             translations, VERSION, BUILD, install script
#     share/applications/           .desktop entry
#     share/icons/hicolor/          app icon
#     share/metainfo/               AppStream data
#
# plus a .tar.gz of it and its SHA-256 (what install-linux.sh downloads).
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="$(Scripts/linux/version.sh)"
ARCH="$(uname -m)"
case "$ARCH" in x86_64) ARCH=x86_64 ;; aarch64|arm64) ARCH=aarch64 ;; esac
NAME="git-cowork-$VERSION-linux-$ARCH"
OUT="dist/linux/$NAME"
CONFIG="${CONFIG:-release}"

echo "→ Building $CONFIG binaries"
FLAGS=(-c "$CONFIG")
[ "$CONFIG" = release ] && FLAGS+=(--static-swift-stdlib)
if ! LOG="$(swift build "${FLAGS[@]}" --product git-cowork-gtk 2>&1 && swift build "${FLAGS[@]}" --product git-cowork 2>&1)"; then
  echo "$LOG"; echo "Build failed"; exit 1
fi
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)"

echo "→ Assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/share/git-cowork/linux" "$OUT/share/applications" \
         "$OUT/share/icons/hicolor/scalable/apps" "$OUT/share/metainfo"
install -m 755 "$BIN/git-cowork-gtk" "$BIN/git-cowork" "$OUT/bin/"
if [ "$CONFIG" = release ] && command -v strip >/dev/null; then strip "$OUT/bin/git-cowork-gtk" "$OUT/bin/git-cowork"; fi
cp -R Resources/*.lproj "$OUT/share/git-cowork/"
cp -R Resources/linux/*.lproj "$OUT/share/git-cowork/linux/"
cp Resources/Info.plist "$OUT/share/git-cowork/Info.plist"
echo "$VERSION" > "$OUT/share/git-cowork/VERSION"
git describe --always --dirty --abbrev=7 --exclude '*' 2>/dev/null > "$OUT/share/git-cowork/BUILD" || echo unknown > "$OUT/share/git-cowork/BUILD"
echo "${GIT_COWORK_REPO:-hanneseilers/git-cowork-linux}" > "$OUT/share/git-cowork/REPOSITORY"
# The in-app updater runs this copy (not one fetched from the web).
install -m 755 install-linux.sh "$OUT/share/git-cowork/install-linux.sh"
cp Resources/linux/dev.gitcowork.GitCowork.desktop "$OUT/share/applications/"
cp Resources/linux/dev.gitcowork.GitCowork.svg "$OUT/share/icons/hicolor/scalable/apps/"
cp Resources/linux/dev.gitcowork.GitCowork.metainfo.xml "$OUT/share/metainfo/"
cp LICENSE "$OUT/share/git-cowork/LICENSE"

echo "→ Packing"
( cd dist/linux && tar -czf "$NAME.tar.gz" "$NAME" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
echo "✓ Built $OUT ($VERSION, $(cat "$OUT/share/git-cowork/BUILD"))"
echo "  dist/linux/$NAME.tar.gz"
