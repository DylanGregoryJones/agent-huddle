#!/bin/bash
# Usage: scripts/build.sh [hook|settings|app|all]   (default: all)
# Each program is built for Apple silicon and Intel and joined into one "universal" file,
# so the same build runs on any Mac with macOS 14 (Sonoma) or later.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
SDK="$(scripts/sdk.sh)"
MIN_MACOS=14.0   # PhaseAnimator (used by the creature icon) needs macOS 14

# universal OUT OPT SOURCES...   OPT is -O for the app and -Onone for the tools.
universal() {
  local out="$1" opt="$2"; shift 2
  local arch parts=()
  for arch in arm64 x86_64; do
    swiftc "$opt" -sdk "$SDK" -target "$arch-apple-macos$MIN_MACOS" "$@" -o "$out.$arch"
    parts+=("$out.$arch")
  done
  lipo -create "${parts[@]}" -output "$out"
  rm -f "${parts[@]}"
}

build_hook() {
  universal build/huddle-permission-hook -Onone Sources/Core/*.swift Sources/Hook/*.swift
}

build_settings() {
  universal build/huddle-settings -Onone Sources/Core/*.swift Sources/SettingsTool/*.swift
}

build_app() {
  local app="build/Agent Huddle.app"
  mkdir -p "$app/Contents/MacOS"
  universal "$app/Contents/MacOS/AgentHuddle" -O Sources/Core/*.swift Sources/App/*.swift Sources/App/Views/*.swift
  cp Resources/Info.plist "$app/Contents/Info.plist"
  codesign --force --sign - "$app"
}

target="${1:-all}"
case "$target" in
  hook) build_hook ;;
  settings) build_settings ;;
  app) build_app ;;
  all)
    if [ -d Sources/Hook ]; then build_hook; fi
    if [ -d Sources/SettingsTool ]; then build_settings; fi
    if [ -d Sources/App ]; then build_app; fi
    ;;
  *) echo "usage: build.sh [hook|settings|app|all]" >&2; exit 2 ;;
esac
