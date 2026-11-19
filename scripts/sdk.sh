#!/bin/bash
# Print a macOS SDK path that the installed Swift compiler can read.
# Each Swift release needs an SDK from the same release, otherwise compiling fails with
# "cannot suppress '~Copyable'". Look in Command Line Tools and in any installed Xcode.
ver="$(swiftc --version 2>/dev/null | grep -o 'swiftlang-[0-9.]*' | head -1)"
dirs=(/Library/Developer/CommandLineTools/SDKs)
for x in /Applications/Xcode*.app; do
  [ -d "$x" ] && dirs+=("$x/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs")
done
if [ -n "$ver" ]; then
  for d in "${dirs[@]}"; do
    for sdk in $(ls -d "$d"/MacOSX*.sdk 2>/dev/null | sort -rV); do
      for f in "$sdk"/usr/lib/swift/Swift.swiftmodule/*-apple-macos.swiftinterface; do
        if [ -f "$f" ] && head -5 "$f" | grep -q -- "$ver"; then echo "$sdk"; exit 0; fi
      done
    done
  done
fi
# No exact match: use the active SDK and let the compiler say if it cannot read it.
if sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" && [ -d "$sdk" ]; then
  echo "sdk.sh: no SDK matches the compiler ${ver:-(unknown)}; using $sdk" >&2
  echo "$sdk"
  exit 0
fi
echo "sdk.sh: no macOS SDK found. Install the developer tools: xcode-select --install" >&2
exit 1
