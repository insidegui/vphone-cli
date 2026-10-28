#!/bin/zsh
set -euo pipefail
component="${0:a:h}"
work="${1:?build directory}"
stage="${2:?stage directory}"
mkdir -p "$work" "$stage"
rm -rf "$work/dropbear" "$work/dash"
mkdir -p "$work/dropbear" "$work/dash"
tar -xzf "$component/ThirdParty/dropbear-2026.94.tar.gz" -C "$work/dropbear" --strip-components=1
tar -xzf "$component/ThirdParty/dash-0.5.13.5.tar.gz" -C "$work/dash" --strip-components=1
patch -s --fuzz=0 -d "$work/dropbear" -p1 < "$component/dropbear-darwinos.patch"
patch -s --fuzz=0 -d "$work/dash" -p1 < "$component/dash-darwinos.patch"
cp "$component/platform.h" "$work/dash/src/vphone-platform.h"
cp "$component/localoptions.h" "$work/dropbear/localoptions.h"
compiler="$(xcrun --sdk iphoneos --find clang)"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
flags="-arch arm64e -isysroot $sdk -miphoneos-version-min=26.4 -Os -include $component/platform.h"
link_flags="-arch arm64e -isysroot $sdk -miphoneos-version-min=26.4 $work/platform.o"
"$compiler" -arch arm64e -isysroot "$sdk" -miphoneos-version-min=26.4 -Os -c "$component/platform.c" -o "$work/platform.o"
(
    cd "$work/dropbear"
    CC="$compiler" CFLAGS="$flags -DVPHONE_DARWINOS=1" LDFLAGS="$link_flags" \
        ./configure --host=aarch64-apple-darwin --disable-zlib --disable-syslog \
        --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx --disable-lastlog > configure.log 2>&1
    make -j4 PROGRAMS="dropbear dropbearkey" > build.log 2>&1
)
(
    cd "$work/dash"
    CC="$compiler" CFLAGS="-arch arm64e -isysroot $sdk -miphoneos-version-min=26.4 -Os" LDFLAGS="$link_flags" \
        CC_FOR_BUILD="$(xcrun --sdk macosx --find clang) -isysroot $(xcrun --sdk macosx --show-sdk-path)" \
        ./configure --host=aarch64-apple-darwin --without-libedit > configure.log 2>&1
    make -j4 > build.log 2>&1
)
cp "$work/dropbear/dropbear" "$stage/vphone-sshd"
cp "$work/dropbear/dropbearkey" "$stage/vphone-ssh-keygen"
cp "$work/dash/src/dash" "$stage/vphone-sh"
for binary in vphone-sshd vphone-ssh-keygen vphone-sh; do
    codesign --force --sign - --entitlements "$component/StudioDisplaySSH.entitlements" "$stage/$binary"
done
cp "$component/ThirdParty/Dropbear-LICENSE" "$component/ThirdParty/Dash-COPYING" "$stage/"
