#!/bin/bash
set -e
cd "$(dirname "$0")/.."
mkdir -p build
SDK="$(scripts/sdk.sh)"
# Tests run on this Mac, so they are built for its own chip only.
ARCH="$(uname -m)"
scripts/build.sh hook
scripts/build.sh settings
swiftc -sdk "$SDK" -target "$ARCH-apple-macos14.0" Sources/Core/*.swift Tests/*.swift -o build/huddle-tests
build/huddle-tests "$@"
