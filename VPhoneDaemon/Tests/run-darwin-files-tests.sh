#!/bin/zsh
set -euo pipefail

daemon="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-darwin-files.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT
/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$temporary/module-cache" \
    "$daemon/vphoned-darwinos/VPhoneDarwinFileSystem.swift" \
    "$daemon/Tests/DarwinFileSystemTests.swift" \
    -o "$temporary/darwin-files-tests"
"$temporary/darwin-files-tests"
