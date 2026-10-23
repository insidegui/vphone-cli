#!/bin/zsh
set -euo pipefail
tests="${0:a:h}"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/vphone-homepod-hid.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-nullability-completeness \
    -fmodules-cache-path="$temporary/modules" -framework Foundation \
    "$tests/HomePodHIDTests.m" -o "$temporary/homepod-hid-tests"
"$temporary/homepod-hid-tests"
