#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "Removing Agent Huddle..."

if [ "${AGENT_HUDDLE_NO_OPEN:-}" != "1" ]; then
  pkill -x AgentHuddle || true
fi

if [ ! -x build/huddle-settings ] && [ "${AGENT_HUDDLE_SKIP_BUILD:-}" != "1" ]; then
  mkdir -p build
  scripts/build.sh settings > build/build.log 2>&1 || {
    cat build/build.log
    echo
    echo "Could not prepare the tool that tidies your Claude settings."
    echo "Agent Huddle was closed but nothing was removed. Please send a screenshot of this window to whoever set this up."
    exit 1
  }
fi

if [ ! -x build/huddle-settings ]; then
  echo "Could not find the tool that tidies your Claude settings."
  echo "Agent Huddle was closed but nothing was removed."
  exit 1
fi

build/huddle-settings uninstall "$HOME/.claude/settings.json" || {
  echo
  echo "Could not tidy your Claude settings."
  echo "Agent Huddle was closed but nothing was removed. Please send a screenshot of this window to whoever set this up."
  exit 1
}

rm -f "$HOME/Library/LaunchAgents/local.agenthuddle.plist"
rm -rf "$HOME/Applications/Agent Huddle.app"
rm -rf "$HOME/.agent-huddle"

echo
echo "Agent Huddle is removed."
echo
