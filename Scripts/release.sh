#!/bin/bash
# Cuts a release: sets the version in Info.plist, dates the changelog,
# commits and creates an annotated tag. Pushing is left to you.
# Usage: Scripts/release.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: make release VERSION=x.y.z   (current: $(Scripts/version.sh))"; exit 1
fi
TAG="v$VERSION"

[ "$(git branch --show-current)" = "main" ] || { echo "Release from main."; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first."; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "$TAG already exists."; exit 1; fi

# The [Unreleased] section must have entries.
NOTES="$(awk '/^## \[Unreleased\]/{f=1;next} /^## /{f=0} f' CHANGELOG.md | grep -v '^[[:space:]]*$' || true)"
[ -n "$NOTES" ] || { echo "Add notes under '## [Unreleased]' in CHANGELOG.md first."; exit 1; }

echo "→ Running tests"
swift test >/dev/null 2>&1 || { echo "Tests fail; fix them first (make test)."; exit 1; }

echo "→ Setting version $VERSION"
# Edit just the one line, so the file keeps its formatting (plutil would rewrite it all).
sed -i '' "/<key>CFBundleShortVersionString<\/key>/{n;s|<string>.*</string>|<string>$VERSION</string>|;}" Resources/Info.plist
[ "$(Scripts/version.sh)" = "$VERSION" ] || { echo "Couldn't set the version in Resources/Info.plist."; exit 1; }
TODAY="$(date +%Y-%m-%d)"
awk -v v="$VERSION" -v d="$TODAY" \
  '{print} /^## \[Unreleased\]$/{print ""; print "## [" v "] - " d}' CHANGELOG.md > CHANGELOG.md.tmp
mv CHANGELOG.md.tmp CHANGELOG.md

git add Resources/Info.plist CHANGELOG.md
git commit -q -m "Release $TAG"
git tag -a "$TAG" -m "git-cowork $VERSION"

echo "✓ Tagged $TAG. Publish it with:"
echo "    git push origin main $TAG"
