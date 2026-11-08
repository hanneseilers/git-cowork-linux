#!/bin/bash
# Brings changes from the original (macOS) repository into this branch:
# fetches upstream/main, merges it, then builds and tests the Linux port.
#
#   Scripts/linux/sync-upstream.sh        (make sync-upstream)
#
# UPSTREAM_URL overrides the original repository's URL.
set -euo pipefail
cd "$(dirname "$0")/../.."
URL="${UPSTREAM_URL:-https://github.com/michael-smao/git-cowork.git}"

[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "Commit or stash your changes first."; exit 1; }
if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "→ Adding remote 'upstream' ($URL)"
  git remote add upstream "$URL"
fi
echo "→ Fetching upstream"
git fetch --no-tags upstream main
# README.md is the Linux README (see .gitattributes): keep ours on merges.
git config merge.ours.driver true
BASE="$(git merge-base HEAD upstream/main)"
echo "→ Merging upstream/main into $(git branch --show-current)"
if ! git merge --no-edit upstream/main; then
  cat <<'HELP'

Merge conflicts. Where they usually are and how to resolve them:
  Package.swift              keep upstream's part, then the "#if os(Linux)" block at the end
  Sources/GitCowork/Git/GitRunner.swift, Accounts/Accounts.swift,
  Sources/CoworkKit/GitExecutor.swift
                             keep upstream's change and the "#if os(Linux)" branch around Process
  Sources/GitCoworkCore/Accounts/SSHKey.swift
                             keep the "#if os(macOS)" around UseKeychain
  Sources/GitCowork/Git/RepoActions.swift
                             keep "#if os(macOS)" around enum External
Then: git add <files> && git commit, and run make test (Linux) before pushing.
New files in Sources/GitCowork/Git or Accounts that the Linux app should use:
add them to sharedAppSources at the end of Package.swift.
HELP
  exit 1
fi
if [ -n "$(git diff --name-only "$BASE" upstream/main -- README.md)" ]; then
  echo "  Upstream changed README.md; the Linux README was kept. Their changes, to carry over by hand if useful:"
  echo "    git diff $BASE upstream/main -- README.md"
fi
echo "→ Building and testing the Linux port"
swift build && swift test
echo "✓ Upstream merged and the Linux build passes. Review, then push."
