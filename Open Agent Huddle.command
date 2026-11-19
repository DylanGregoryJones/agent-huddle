#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d "$HOME/Applications/Agent Huddle.app" ]; then
  echo "Agent Huddle is not installed. Double-click Install Agent Huddle.command first."
  exit 1
fi
open -g "$HOME/Applications/Agent Huddle.app"
