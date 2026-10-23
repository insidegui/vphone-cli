#!/bin/zsh
set -euo pipefail

tests="${0:a:h}"
repo="${tests:h:h:h}"
out="$repo/.build/homepod-defaults-tests"
mkdir -p "$out"
xcrun --sdk macosx swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -module-cache-path "$out/module-cache" \
    "$tests:h/UI/UserInterface/Panels/Controls/VPhoneHomePodDefaultsModel.swift" \
    "$tests:h/UI/UserInterface/Panels/Controls/VPhoneHomePodDefaultsView.swift" \
    "$tests:h/UI/UserInterface/Panels/Controls/VPhoneHomePodDebugModel.swift" \
    "$tests/HomePodDefaultsTests.swift" -o "$out/HomePodDefaultsTests"
"$out/HomePodDefaultsTests" "$@"
