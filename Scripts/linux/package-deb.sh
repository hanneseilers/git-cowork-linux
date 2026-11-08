#!/bin/bash
# Makes a .deb (Debian 13+, Ubuntu 24.04+) from the tree Scripts/linux/build.sh made.
# Installs into /usr; apt keeps it updated, the in-app updater stays off.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="$(Scripts/linux/version.sh)"
ARCH="$(uname -m)"; case "$ARCH" in x86_64) ARCH=x86_64; DEBARCH=amd64 ;; aarch64|arm64) ARCH=aarch64; DEBARCH=arm64 ;; *) DEBARCH="$ARCH" ;; esac
TREE="dist/linux/git-cowork-$VERSION-linux-$ARCH"
[ -d "$TREE" ] || Scripts/linux/build.sh
DEB="dist/linux/git-cowork_${VERSION}_${DEBARCH}.deb"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/usr" "$ROOT/DEBIAN"
cp -R "$TREE/bin" "$TREE/share" "$ROOT/usr/"
# apt updates this install; the app's own updater checks for this file.
rm -f "$ROOT/usr/share/git-cowork/install-linux.sh"
mkdir -p "$ROOT/usr/share/doc/git-cowork"
cp LICENSE "$ROOT/usr/share/doc/git-cowork/copyright"
SIZE="$(du -sk "$ROOT/usr" | cut -f1)"
cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: git-cowork
Version: $VERSION
Architecture: $DEBARCH
Maintainer: git-cowork for Linux <noreply@github.com>
Installed-Size: $SIZE
Depends: git, libgtk-4-1 (>= 4.12), libadwaita-1-0 (>= 1.5), libsecret-1-0, libcurl4t64 | libcurl4, libc6 (>= 2.34)
Recommends: openssh-client, gnome-keyring | kwalletmanager | keepassxc, xdg-utils
Section: devel
Priority: optional
Homepage: https://github.com/hanneseilers/git-cowork-linux
Description: Git client with a task board and code reviews inside your repo
 A small, fast GTK 4 git client that runs plain git underneath and shows
 every command it runs. Branches and worktrees in one graph, a shared task
 board and review requests stored on a hidden git ref, and the
 `git cowork` command-line tool for the same tasks.
CONTROL
chmod 0755 "$ROOT/DEBIAN"
dpkg-deb --root-owner-group --build "$ROOT" "$DEB" >/dev/null
( cd dist/linux && sha256sum "$(basename "$DEB")" > "$(basename "$DEB").sha256" )
echo "✓ Built $DEB"
