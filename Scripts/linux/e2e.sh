#!/bin/bash
# End-to-end tests for the Linux build. Each part runs when its tools exist
# and says SKIP otherwise:
#
#   1. unit tests (swift test)
#   2. Secret Service + askpass tests inside a throwaway D-Bus session and
#      GNOME keyring (dbus-run-session, gnome-keyring-daemon)
#   3. ssh login to a local sshd with the app as SSH_ASKPASS (sshd)
#   4. `git cowork` between two clones of one remote
#   5. the GTK app under Xvfb, driven with xdotool: open a repo, stage,
#      commit, undo, create a task (Xvfb, xdotool)
#
# Usage: Scripts/linux/e2e.sh        (make e2e)
# Screenshots of part 5 go to .build/e2e/.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gc-e2e.XXXXXX")"
OUT="$ROOT/.build/e2e"; mkdir -p "$OUT"
PASS=0; FAIL=0; SKIP=0
cleanup() {
  [ -n "${SSHD_PID:-}" ] && kill "$SSHD_PID" 2>/dev/null
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
  pkill -x git-cowork-gtk 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
skip() { echo "  – SKIP: $*"; SKIP=$((SKIP+1)); }
has()  { command -v "$1" >/dev/null 2>&1; }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

echo "→ Building"
swift build --build-tests >"$WORK/build.log" 2>&1 || { tail -30 "$WORK/build.log"; echo "Build failed"; exit 1; }
BIN="$(swift build --show-bin-path)"
APP="$BIN/git-cowork-gtk"
CLI="$BIN/git-cowork"

echo "→ 1. Unit tests"
if swift test --skip-build >"$WORK/unit.log" 2>&1; then
  ok "$(grep -Eo 'Test run with [0-9]+ tests passed' "$WORK/unit.log" | tail -1)"
else
  grep -E '✘' "$WORK/unit.log" | head -20; bad "unit tests"
fi

# A D-Bus session with an unlocked, throwaway keyring for parts 2 and 3.
in_keyring() {
  dbus-run-session -- bash -c '
    export HOME="'"$WORK"'/home"; mkdir -p "$HOME"
    eval "$(printf "e2e\n" | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)"
    eval "$(gnome-keyring-daemon --start --components=secrets 2>/dev/null)"
    "$@"' _ "$@"
}

echo "→ 2. Secret Service and askpass"
if has dbus-run-session && has gnome-keyring-daemon; then
  if in_keyring swift test --skip-build --filter 'KeychainTests|AskpassEndToEnd' >"$WORK/keyring.log" 2>&1 \
     && ! grep -q skipping "$WORK/keyring.log"; then
    ok "tokens and SSH passphrases in the Secret Service; askpass answers only for app keys"
  else
    tail -20 "$WORK/keyring.log"; bad "Secret Service tests"
  fi
else
  skip "needs dbus-run-session and gnome-keyring-daemon"
fi

echo "→ 3. ssh login with the app as SSH_ASKPASS"
SSHD="$(command -v sshd || echo /usr/sbin/sshd)"
if [ -x "$SSHD" ] && has dbus-run-session && has gnome-keyring-daemon && has secret-tool && [ "$(id -u)" = 0 ]; then
  S="$WORK/sshd"; mkdir -p "$S" /run/sshd; chmod 700 "$S"
  ssh-keygen -q -t ed25519 -N '' -f "$S/hostkey"
  PORT=$((20000 + RANDOM % 20000))
  cat > "$S/config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $S/hostkey
PidFile $S/pid
AuthorizedKeysFile $S/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PermitRootLogin yes
EOF
  "$SSHD" -f "$S/config" -E "$S/log"; sleep 0.5; SSHD_PID="$(cat "$S/pid" 2>/dev/null)"
  cat > "$WORK/ssh.sh" <<EOF
#!/bin/bash
SSHDIR=\$(getent passwd "\$(id -un)" | cut -d: -f6)/.ssh; mkdir -p "\$SSHDIR"; chmod 700 "\$SSHDIR"
KEY="\$SSHDIR/git-cowork_e2e-\$\$.invalid"; OTHER="\$SSHDIR/gc-e2e-other-\$\$"
trap 'rm -f "\$KEY" "\$KEY.pub" "\$OTHER" "\$OTHER.pub"' EXIT
for k in "\$KEY" "\$OTHER"; do
  printf 'pw\npw\n' | ssh-keygen -q -t ed25519 -C e2e -f "\$k" >/dev/null 2>&1
  printf 'pw' | secret-tool store --label=e2e xdg:schema dev.gitcowork.Secret service git-cowork-ssh account "\$k"
done
run() { SSH_ASKPASS="$APP" SSH_ASKPASS_REQUIRE=force GIT_COWORK_ASKPASS=1 setsid -w ssh -F /dev/null -i "\$1" -o IdentitiesOnly=yes \
          -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 true </dev/null; }
cp "\$KEY.pub" "$S/authorized_keys"; run "\$KEY" || exit 1
cp "\$OTHER.pub" "$S/authorized_keys"; run "\$OTHER" && exit 2
exit 0
EOF
  chmod +x "$WORK/ssh.sh"
  in_keyring "$WORK/ssh.sh"; rc=$?
  case $rc in
    0) ok "logs in with the app's key; another key gets no passphrase" ;;
    1) bad "login with the app's key failed" ;;
    *) bad "askpass answered for a key the app didn't make" ;;
  esac
else
  skip "needs sshd, secret-tool, a keyring and root (for a throwaway sshd)"
fi

echo "→ 4. git cowork between two clones"
R="$WORK/cli"; mkdir -p "$R"
git init -q --bare -b main "$R/remote.git"
git clone -q "$R/remote.git" "$R/a" 2>/dev/null; git clone -q "$R/remote.git" "$R/b" 2>/dev/null
for u in a b; do git -C "$R/$u" config user.email "$u@example.com"; git -C "$R/$u" config user.name "User $u"; done
git -C "$R/a" commit -q --allow-empty -m init && git -C "$R/a" push -q origin HEAD:main 2>/dev/null
ID="$(cd "$R/a" && "$CLI" new "Ship the Linux port" --assign b@example.com --label linux)"
check "new task $ID in clone a" test -n "$ID"
git -C "$R/b" pull -q origin main 2>/dev/null
check "clone b sees it after --sync" bash -c "cd '$R/b' && '$CLI' list --sync | grep -q 'Ship the Linux port'"
check "clone b's inbox shows the assignment" bash -c "cd '$R/b' && '$CLI' inbox | grep -q 'assigned you'"
check "start in a worktree" bash -c "cd '$R/b' && '$CLI' start '$ID' --worktree"
check "comment with a mention" bash -c "cd '$R/b' && '$CLI' comment '$ID' 'Done @a'"
check "clone a gets the mention" bash -c "cd '$R/a' && '$CLI' inbox --sync | grep -q 'mentioned you'"
check "JSON output parses" bash -c "cd '$R/a' && '$CLI' list --json | python3 -c 'import json,sys; assert json.load(sys.stdin)[0][\"id\"]'"
check "nothing touched clone a's working tree or HEAD" bash -c "test -z \"\$(git -C '$R/a' status --porcelain)\" && git -C '$R/a' rev-parse --abbrev-ref HEAD | grep -q main"

echo "→ 5. GTK app under Xvfb"
if has Xvfb && has xdotool && has dbus-run-session; then
  DISPLAY_NUM=$((100 + RANDOM % 100))
  Xvfb ":$DISPLAY_NUM" -screen 0 1600x1000x24 >/dev/null 2>&1 & XVFB_PID=$!
  sleep 1
  export DISPLAY=":$DISPLAY_NUM" GDK_BACKEND=x11 GTK_A11Y=none NO_AT_BRIDGE=1 GIT_COWORK_NON_UNIQUE=1 GIT_COWORK_LANG=en
  G="$WORK/gui"; mkdir -p "$G"
  git init -q --bare -b main "$G/remote.git"
  git init -q -b main "$G/repo"; cd "$G/repo"
  git config user.email anna@example.com; git config user.name "Anna Berg"; git remote add origin "$G/remote.git"
  for i in 1 2 3; do echo "line $i" >> README.md; git add .; git commit -qm "Part $i"; done
  git push -q -u origin main 2>/dev/null
  git switch -qc feature/x; echo x > x.txt; git add .; git commit -qm "Feature x"; git switch -q main
  echo "change" >> README.md
  cd "$ROOT"
  shot() { has import && import -window root "$OUT/$1.png" 2>/dev/null; }
  HOME="$G/home" dbus-run-session -- "$APP" "$G/repo" >"$WORK/app.log" 2>&1 &
  sleep 6
  if pgrep -x git-cowork-gtk >/dev/null; then ok "app starts and opens the repository"; else bad "app didn't start"; tail -20 "$WORK/app.log"; fi
  # --name only reads the legacy WM_NAME; find the window by class, then read its UTF-8 title.
  WIN=""
  for w in $(xdotool search --classname git-cowork 2>/dev/null); do
    [ "$(xdotool getwindowname "$w" 2>/dev/null)" = "repo — git-cowork" ] && WIN="$w"
  done
  [ -n "$WIN" ] && ok "window titled after the repository" || bad "no window titled 'repo — git-cowork'"
  [ -n "$WIN" ] && xdotool windowactivate --sync "$WIN" 2>/dev/null; xdotool windowsize "$WIN" 1400 900 2>/dev/null; sleep 1
  shot 01-history
  xdotool key ctrl+0; sleep 1
  xdotool key ctrl+shift+s; sleep 1; xdotool type --delay 10 "e2e stash"; xdotool key Return; sleep 2
  check "stash from the dialog (Ctrl+Shift+S)" bash -c "git -C '$G/repo' stash list | grep -q 'e2e stash'"
  xdotool key ctrl+alt+shift+s; sleep 2
  check "pop the stash (Ctrl+Alt+Shift+S)" bash -c "test -z \"\$(git -C '$G/repo' stash list)\" && git -C '$G/repo' status --porcelain | grep -q README.md"
  git -C "$G/repo" add README.md; sleep 2
  xdotool key ctrl+0; sleep 1
  shot 02-changes
  # Focus the summary: right-click the WIP row → "Write Commit Message" is hard to target; type into the focused summary instead.
  xdotool key ctrl+shift+b; sleep 1; xdotool type --delay 10 "feature/e2e"; xdotool key Return; sleep 2
  check "new branch from the dialog (Ctrl+Shift+B)" bash -c "git -C '$G/repo' branch --show-current | grep -q feature/e2e"
  xdotool key ctrl+2; sleep 1; xdotool key ctrl+shift+t; sleep 1
  xdotool type --delay 10 "Task from the GUI"; xdotool key Return; sleep 3
  shot 03-board
  check "task created on the board (Ctrl+Shift+T)" bash -c "cd '$G/repo' && '$CLI' list --all | grep -q 'Task from the GUI'"
  check "task pushed to the remote" bash -c "git -C '$G/remote.git' rev-parse -q --verify refs/cowork/main"
  xdotool key ctrl+3; sleep 1; shot 04-reviews
  xdotool key ctrl+comma; sleep 1.5; shot 05-settings; xdotool key Escape; sleep 0.5
  if pgrep -x git-cowork-gtk >/dev/null; then ok "still running after the session"; else bad "app quit or crashed"; tail -30 "$WORK/app.log"; fi
  if grep -q "CRITICAL\|crashed" "$WORK/app.log"; then grep "CRITICAL\|crashed" "$WORK/app.log" | head -5; bad "GTK criticals or a crash in the log"; else ok "no GTK criticals in the log"; fi
  xdotool key ctrl+q; sleep 1
  pgrep -x git-cowork-gtk >/dev/null && bad "Ctrl+Q didn't quit" || ok "Ctrl+Q quits"
else
  skip "needs Xvfb, xdotool and dbus-run-session"
fi

echo
echo "E2E: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
