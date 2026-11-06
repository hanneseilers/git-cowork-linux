#!/bin/bash
# Builds dist/git-cowork.app (release, Apple Silicon) and signs it ad-hoc.
# No Apple Developer account needed: apps you build yourself aren't quarantined.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/git-cowork.app"
echo "→ Building release binary"
swift build -c release --arch arm64 2>&1 | grep -vE '^\[[0-9]+/[0-9]+\]' || true
BIN="$(swift build -c release --arch arm64 --show-bin-path)/GitCowork"
[ -x "$BIN" ] || { echo "Build failed"; exit 1; }

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GitCowork"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f .build/AppIcon.icns ]; then
  echo "→ Drawing icon"
  ICONSET=.build/AppIcon.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  swift Scripts/make-icon.swift .build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s .build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) .build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o .build/AppIcon.icns
fi
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "→ Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
echo "✓ Built $APP"
