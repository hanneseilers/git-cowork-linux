#!/bin/bash
# Installs a tree made by Scripts/linux/build.sh into GIT_COWORK_PREFIX
# (default ~/.local). Used by `make install`.
set -euo pipefail
TREE="${1:?usage: install-tree.sh <tree>}"
PREFIX="${GIT_COWORK_PREFIX:-$HOME/.local}"
mkdir -p "$PREFIX/bin" "$PREFIX/share/applications" "$PREFIX/share/icons/hicolor/scalable/apps" "$PREFIX/share/metainfo"
rm -rf "$PREFIX/share/git-cowork.new"
cp -R "$TREE/share/git-cowork" "$PREFIX/share/git-cowork.new"
rm -rf "$PREFIX/share/git-cowork"
mv "$PREFIX/share/git-cowork.new" "$PREFIX/share/git-cowork"
for b in git-cowork-gtk git-cowork; do
  install -m 755 "$TREE/bin/$b" "$PREFIX/bin/.$b.new"
  mv -f "$PREFIX/bin/.$b.new" "$PREFIX/bin/$b"
done
sed "s|^Exec=git-cowork-gtk|Exec=$PREFIX/bin/git-cowork-gtk|" "$TREE/share/applications/dev.gitcowork.GitCowork.desktop" \
  > "$PREFIX/share/applications/dev.gitcowork.GitCowork.desktop"
cp "$TREE/share/icons/hicolor/scalable/apps/dev.gitcowork.GitCowork.svg" "$PREFIX/share/icons/hicolor/scalable/apps/"
cp "$TREE/share/metainfo/dev.gitcowork.GitCowork.metainfo.xml" "$PREFIX/share/metainfo/"
command -v update-desktop-database >/dev/null && update-desktop-database -q "$PREFIX/share/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$PREFIX/share/icons/hicolor" 2>/dev/null || true
echo "✓ Installed git-cowork $(cat "$TREE/share/git-cowork/VERSION") into $PREFIX"
case ":$PATH:" in *":$PREFIX/bin:"*) ;; *) echo "  $PREFIX/bin isn't on your PATH yet: echo 'export PATH=\"$PREFIX/bin:\$PATH\"' >> ~/.bashrc";; esac
