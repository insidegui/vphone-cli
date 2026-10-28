#!/bin/zsh
set -euo pipefail
component="${0:a:h}"
work="${1:?build directory}"
stage="${2:?stage directory}"
rm -rf "$work"
mkdir -p "$work" "$stage"
tar -xzf "$component/ThirdParty/toybox-0.8.15.tar.gz" -C "$work" --strip-components=1
patch -s --fuzz=0 -d "$work" -p1 < "$component/toybox-darwinos.patch"
mac_sdk="$(xcrun --sdk macosx --show-sdk-path)"
compiler="$(xcrun --sdk iphoneos --find clang)"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
host_compiler="$(xcrun --sdk macosx --find clang) -isysroot $mac_sdk"
(
    cd "$work"
    # Toybox's prerequisite tool supplies the GNU-compatible sed used by its
    # generators. It runs on the Mac, never in the guest, and needs no Homebrew.
    SDKROOT="$mac_sdk" /bin/sh scripts/prereq/build.sh > prereq.log 2>&1
    mkdir prereq
    for applet in $(./toybox-prereq); do ln -s ../toybox-prereq "prereq/$applet"; done
    for tool in cc as ld strip bash; do ln -s "$(command -v "$tool")" "prereq/$tool"; done
    # Only this missing Darwin header is borrowed; all libraries and other
    # headers come from the iPhoneOS SDK. Its ioctl ABI is shared by XNU.
    mkdir -p include/sys
    cp "$mac_sdk/usr/include/sys/disk.h" include/sys/
    "$compiler" -arch arm64e -isysroot "$sdk" -miphoneos-version-min=26.4 -Os \
        -c "$component/platform.c" -o platform.o
    export CC="$compiler" HOSTCC="$host_compiler" CPUS=4 VERSION=0.8.15
    export CFLAGS="-arch arm64e -isysroot $sdk -miphoneos-version-min=26.4 -I $work/include -include $component/platform.h"
    export LDFLAGS="-arch arm64e -isysroot $sdk -miphoneos-version-min=26.4 $work/platform.o"
    export PATH="$work/prereq:/usr/bin:/bin:/usr/sbin:/sbin"
    # Xcode exports SED=/usr/bin/sed; the generators require Toybox's sed.
    export SED="$work/prereq/sed"
    export KCONFIG_ALLCONFIG="$component/toybox_miniconfig"
    bash scripts/genconfig.sh -n > configure.log 2>&1
    bash scripts/make.sh > build.log 2>&1
    # This host tool reads the final generated configuration, including aliases.
    # Never execute a guest binary to generate the installer manifest.
    ${=host_compiler} -I . scripts/install.c -o applet-list
    ./applet-list > "$stage/vphone-tools-applets.txt"
    cp toybox "$stage/vphone-tools"
)
codesign --force --sign - --entitlements "$component/StudioDisplaySSH.entitlements" "$stage/vphone-tools"
cp "$component/ThirdParty/Toybox-LICENSE" "$stage/"
