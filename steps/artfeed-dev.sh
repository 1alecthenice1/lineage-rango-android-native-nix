#!/usr/bin/env bash
# Build extras/ArtFeed on the build host and install it on the phone, without a LineageOS build
# (the real build compiles it from extras/ArtFeed/Android.bp).
#   ./steps/artfeed-dev.sh            build + adb install + start the overlay test
#   ./steps/artfeed-dev.sh build      build only → ~/.cache/artfeed-dev/ArtFeed-dev.apk
# Tools: Google's build-tools 36.1 + platform 36 in ~/.cache/android-sdk (sha1-checked
# downloads); javac/d8/apksigner run natively, aapt2 + zipalign are x86-64 → run in the
# lineage-sign container through qemu-user (NixOS: boot.binfmt.emulatedSystems = [ "x86_64-linux" ]).
# The dev APK is signed with a throwaway debug key: before installing a build that
# contains ArtFeed (build 12+), `adb uninstall lineage.rango.artfeed` first.
set -euo pipefail
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }
cd "$(dirname "$0")/.."
src=$PWD/extras/ArtFeed
sdk=$HOME/.cache/android-sdk
bt=$sdk/android-16            # build-tools 36.1 unpack directory
jar=$sdk/android-36/android.jar
out=$HOME/.cache/artfeed-dev
[ -x "$bt/aapt2" ] && [ -f "$jar" ] || fail "missing build-tools/platform in $sdk: unpack build-tools 36.1 to $bt and platform 36 to $sdk/android-36 (dl.google.com/android/repository)"
jdk=$(nix build --no-link --print-out-paths --inputs-from "$(dirname "$0")/.." nixpkgs#jdk21_headless)/bin
img=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -m1 '^lineage-sign:') || fail "no lineage-sign image (steps/sign.sh builds it)"
x86() { docker run --rm --platform linux/amd64 -v /nix/store:/nix/store:ro -v /run/binfmt:/run/binfmt:ro \
          -v "$sdk":/sdk:ro -v "$src":/src:ro -v "$out":/out "$img" "$@"; }

rm -rf "$out/build"; mkdir -p "$out/build/classes"
x86 /sdk/android-16/aapt2 compile --dir /src/res -o /out/build/res.zip
x86 /sdk/android-16/aapt2 link -I /sdk/android-36/android.jar --manifest /src/AndroidManifest.xml \
    --min-sdk-version 34 --target-sdk-version 36 \
    -o /out/build/base.apk /out/build/res.zip
ok "resources"
"$jdk/javac" -Xlint:-options -Werror -source 17 -target 17 -encoding UTF-8 -classpath "$jar" \
    -d "$out/build/classes" $(find "$src/src" -name '*.java')
ok "javac"
"$jdk/java" -cp "$bt/lib/d8.jar" com.android.tools.r8.D8 --release --min-api 34 --lib "$jar" \
    --output "$out/build" $(find "$out/build/classes" -name '*.class')
cp "$out/build/base.apk" "$out/build/unaligned.apk"
x86 zip -q -j /out/build/unaligned.apk /out/build/classes.dex   # zip: from the container
x86 /sdk/android-16/zipalign -f -p 4 /out/build/unaligned.apk /out/build/aligned.apk
ok "dex + align"
ks=$out/debug.keystore
[ -f "$ks" ] || "$jdk/keytool" -genkeypair -keystore "$ks" -storepass android -keypass android \
    -alias dev -keyalg RSA -keysize 2048 -validity 3650 -dname "CN=ArtFeed dev" >/dev/null 2>&1
"$jdk/java" -jar "$bt/lib/apksigner.jar" sign --ks "$ks" --ks-pass pass:android \
    --out "$out/ArtFeed-dev.apk" "$out/build/aligned.apk"
ok "signed: $out/ArtFeed-dev.apk ($(du -h "$out/ArtFeed-dev.apk" | cut -f1))"
[ "${1:-}" = build ] && exit 0

adb get-state >/dev/null 2>&1 || fail "phone not connected over adb"
adb install -r "$out/ArtFeed-dev.apk" >/dev/null && ok "installed"
adb shell am start -n lineage.rango.artfeed/.PreviewActivity >/dev/null && ok "overlay test started on the phone"
