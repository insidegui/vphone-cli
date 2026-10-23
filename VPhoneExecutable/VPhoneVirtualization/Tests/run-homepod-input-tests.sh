#!/bin/zsh
set -euo pipefail

tests="${0:a:h}"
repo="${tests:h:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-homepod-input.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -strict-concurrency=complete \
    -module-cache-path "$temporary/ModuleCache" -emit-library -emit-module \
    -module-name VPhoneCoreKit -emit-module-path "$temporary/VPhoneCoreKit.swiftmodule" \
    "$repo/VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneHomePodDisplay.swift" \
    -Xlinker -install_name -Xlinker '@rpath/libVPhoneCoreKit.dylib' \
    -o "$temporary/libVPhoneCoreKit.dylib"
/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -strict-concurrency=complete \
    -module-cache-path "$temporary/ModuleCache" -I "$temporary" -L "$temporary" -lVPhoneCoreKit \
    -Xlinker -rpath -Xlinker "$temporary" \
    "$tests/HomePodInputTests.swift" \
    "$tests:h/UI/UserInterface/HomePod/VPhoneHomePodDisplayView.swift" \
    "$tests:h/UI/UserInterface/HomePod/VPhoneHomePodMetalRenderer.swift" \
    "$tests:h/UI/UserInterface/HomePod/VPhoneHomePodShader.swift" \
    -o "$temporary/HomePodInputTests"
"$temporary/HomePodInputTests"
