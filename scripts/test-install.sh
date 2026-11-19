#!/bin/bash
# Runs Install and Uninstall against a throwaway HOME. Never touches the real one.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
scripts/build.sh all

T="$(mktemp -d)"
WAITERS=()
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in "${WAITERS[@]+"${WAITERS[@]}"}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT
fail() { echo "INSTALL TEST FAIL: $1"; exit 1; }
inode() { stat -f %i "$1"; }
# The installed hook runs: exit 0 and nothing on stdout for an empty payload.
hook_runs() { local out; out="$(printf '{}' | "$HOOK" 2>/dev/null)" && [ -z "$out" ]; }

mkdir -p "$T/.claude"
cp Tests/fixtures/settings-orca.json "$T/.claude/settings.json"
export HOME="$T" AGENT_HUDDLE_SKIP_BUILD=1 AGENT_HUDDLE_NO_OPEN=1

"$ROOT/Install Agent Huddle.command" || fail "install exited non-zero"
APP="$T/Applications/Agent Huddle.app"
HOOK="$T/.agent-huddle/bin/huddle-permission-hook"
PLIST="$T/Library/LaunchAgents/local.agenthuddle.plist"
SET="$T/.claude/settings.json"

[ -d "$APP" ] || fail "app missing"
[ -x "$HOOK" ] || fail "hook not executable"
hook_runs || fail "installed hook does not run"
"$ROOT/build/huddle-settings" check "$SET" || fail "settings check failed"
grep -q '"PermissionRequest"' "$SET" || fail "PermissionRequest missing"
python3 -I -c "
import json,sys
d=json.load(open('$SET'))
cmds=[h.get('command','') for e in d['hooks']['PermissionRequest'] for h in e.get('hooks',[])]
sys.exit(0 if any('.orca/' in c for c in cmds) else 1)" || fail "Orca PermissionRequest entry missing"
python3 -I -c "
import json,sys
d=json.load(open('$SET'))
cmds=[h.get('command','') for e in d['hooks']['PermissionRequest'] for h in e.get('hooks',[])]
sys.exit(0 if '$HOOK' in cmds else 1)" || fail "hook command is not exactly the installed hook"
plutil -lint "$PLIST" >/dev/null || fail "plist invalid"
! grep -q KeepAlive "$PLIST" || fail "plist has KeepAlive"
grep -qF "$APP" "$PLIST" || fail "plist lacks app path"
grep -q '<string>-g</string>' "$PLIST" || fail "plist does not open in the background (-g)"
! grep -q '__APP__' "$PLIST" || fail "plist placeholder left"
[ "$(ls "$T/.claude" | grep -c 'agent-huddle-backup')" = 1 ] || fail "expected exactly one backup"

"$ROOT/Install Agent Huddle.command" >/dev/null || fail "second install failed"
"$ROOT/build/huddle-settings" check "$SET" || fail "check failed after reinstall"
[ "$(ls "$T/.claude" | grep -c 'agent-huddle-backup')" = 1 ] || fail "backup count changed after reinstall"
hook_runs || fail "hook does not run after reinstall"

# Reinstall a different hook binary while an old hook is still running (they wait up to an hour).
# Copying over the file in place would get the new binary SIGKILLed by macOS on its next run.
STUB="$T/stub-install"
mkdir -p "$STUB/build" "$STUB/Resources"
cp "$ROOT/Install Agent Huddle.command" "$STUB/"
cp "$ROOT/Resources/local.agenthuddle.plist" "$STUB/Resources/"
cp -R "$ROOT/build/Agent Huddle.app" "$ROOT/build/huddle-settings" "$ROOT/build/huddle-permission-hook" "$STUB/build/"
strip -S "$STUB/build/huddle-permission-hook"
codesign --force --sign - "$STUB/build/huddle-permission-hook" 2>/dev/null
! cmp -s "$STUB/build/huddle-permission-hook" "$HOOK" || fail "test setup: stub hook should differ"
mkfifo "$T/hold"
"$HOOK" < "$T/hold" >/dev/null 2>&1 &
WAITERS+=($!)
exec 3>"$T/hold"   # the old hook waits for the rest of its payload until fd 3 closes
for _ in 1 2 3 4 5 6 7 8 9 10; do
  case "$(ps -o comm= -p "$!")" in *huddle-permission-hook) break ;; esac
  sleep 0.1
done
case "$(ps -o comm= -p "$!")" in *huddle-permission-hook) ;; *) fail "test setup: old hook not running" ;; esac
OLD_INODE="$(inode "$HOOK")"
"$STUB/Install Agent Huddle.command" >/dev/null || fail "reinstall with a different hook failed"
cmp -s "$STUB/build/huddle-permission-hook" "$HOOK" || fail "hook not updated by reinstall"
[ "$(inode "$HOOK")" != "$OLD_INODE" ] || fail "hook was overwritten in place (same inode)"
hook_runs || fail "new hook does not run after reinstall over a running one"
exec 3>&-

"$ROOT/Uninstall Agent Huddle.command" || fail "uninstall exited non-zero"
[ ! -e "$APP" ] || fail "app still there"
[ ! -e "$T/.agent-huddle" ] || fail ".agent-huddle still there"
[ ! -e "$PLIST" ] || fail "plist still there"
cmp -s "$SET" "$ROOT/Tests/fixtures/settings-orca.json" || \
  python3 -c "import json,sys; sys.exit(0 if json.load(open('$SET'))==json.load(open('$ROOT/Tests/fixtures/settings-orca.json')) else 1)" \
  || fail "settings differ from fixture"

# Uninstall again, and Uninstall with nothing installed: both succeed.
"$ROOT/Uninstall Agent Huddle.command" >/dev/null || fail "second uninstall failed"

# Uninstall must refuse, and remove nothing, when the settings tool cannot be built.
mkdir -p "$T/stub/scripts" "$T/.agent-huddle/bin"
printf '#!/bin/bash\nexit 1\n' > "$T/stub/scripts/build.sh"; chmod +x "$T/stub/scripts/build.sh"
cp "$ROOT/Uninstall Agent Huddle.command" "$T/stub/"
echo x > "$T/.agent-huddle/bin/huddle-permission-hook"
unset AGENT_HUDDLE_SKIP_BUILD
if "$T/stub/Uninstall Agent Huddle.command" >/dev/null 2>&1; then fail "uninstall should fail without settings tool"; fi
[ -e "$T/.agent-huddle/bin/huddle-permission-hook" ] || fail "uninstall removed files despite failing"

echo "INSTALL TEST PASS"
