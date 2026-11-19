#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

trap 'echo; echo "Something went wrong, so Agent Huddle was not fully installed."; echo "Please send a screenshot of this window to whoever set this up."; echo' ERR

echo "Installing Agent Huddle..."

if [ "${AGENT_HUDDLE_SKIP_BUILD:-}" != "1" ]; then
  if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Agent Huddle is built on your Mac, and this Mac is missing Apple's developer tools."
    echo "In Terminal, run this command, click Install when asked, wait for it to finish,"
    echo "then double-click this file again:"
    echo "  xcode-select --install"
    exit 1
  fi
  echo "Building (this takes a minute)..."
  mkdir -p build
  scripts/build.sh all > build/build.log 2>&1 || {
    cat build/build.log
    echo; echo "The build failed. Nothing was changed on your Mac."
    exit 1
  }
fi

SRC="$(pwd)/build"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Agent Huddle.app"
BIN="$HOME/.agent-huddle/bin"
HOOK="$BIN/huddle-permission-hook"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/local.agenthuddle.plist"

if [ "${AGENT_HUDDLE_NO_OPEN:-}" != "1" ]; then
  pkill -x AgentHuddle || true
  sleep 1
fi

mkdir -p "$APP_DIR" "$BIN" "$AGENTS" "$HOME/.claude"
chmod 700 "$HOME/.agent-huddle"

rm -rf "$APP"
cp -R "$SRC/Agent Huddle.app" "$APP"

# Never copy over the hook in place: hooks still waiting from earlier sessions keep the old file,
# and macOS kills a signed program whose file changed underneath it. A new file is moved in instead.
rm -f "$BIN"/.huddle-permission-hook.*
NEW_HOOK="$(mktemp "$BIN/.huddle-permission-hook.XXXXXX")"
cp "$SRC/huddle-permission-hook" "$NEW_HOOK"
chmod 755 "$NEW_HOOK"
mv -f "$NEW_HOOK" "$HOOK"

# The hook must run and stay silent before Claude is told to use it.
if ! HOOK_OUT="$(printf '{}' | "$HOOK" 2>/dev/null)" || [ -n "$HOOK_OUT" ]; then
  trap - ERR
  echo
  echo "The permission helper did not start properly, so Agent Huddle is not switched on."
  echo "Your Claude settings were not changed. Please send a screenshot of this window to whoever set this up."
  exit 1
fi

"$SRC/huddle-settings" install "$HOME/.claude/settings.json" "$HOOK" || {
  trap - ERR
  echo
  echo "Your Claude settings were not changed."
  echo "Agent Huddle is not switched on. Please send a screenshot of this window to whoever set this up."
  exit 1
}

sed "s|__APP__|$APP|g" Resources/local.agenthuddle.plist > "$PLIST"

if [ "${AGENT_HUDDLE_NO_OPEN:-}" != "1" ]; then
  open -g "$APP"
fi

trap - ERR
echo
echo "Agent Huddle is installed."
echo "It is open now and will start each time you log in."
echo "Claude sessions you start from now on will show Allow and Deny buttons."
echo
