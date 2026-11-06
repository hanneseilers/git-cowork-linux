#!/bin/bash
# Updates this checkout before `make update` reinstalls the app.
# On a branch (e.g. main): pulls the latest commits.
# On a release tag (detached): moves to the newest release tag.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "You have local changes in this checkout. Commit or stash them, then run make update again."
  exit 1
fi

BRANCH="$(git branch --show-current)"
if [ -n "$BRANCH" ]; then
  echo "→ Pulling latest $BRANCH"
  git pull --ff-only
else
  echo "→ Fetching releases"
  git fetch --tags --quiet
  LATEST="$(git tag --list 'v*' --sort=-v:refname | head -1)"
  [ -n "$LATEST" ] || { echo "No release tags found."; exit 1; }
  if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$LATEST^{commit}")" ]; then
    echo "Already on the newest release, $LATEST."
  else
    echo "→ Switching to $LATEST"
    git -c advice.detachedHead=false checkout --quiet "$LATEST"
  fi
fi
