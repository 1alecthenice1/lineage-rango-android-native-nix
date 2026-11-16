#!/usr/bin/env bash
# First-boot debugging for a user build (ro.debuggable=0: recovery has no "Enable ADB",
# Android has ADB off until setup is done). Builds a throwaway init_boot from the
# build's Magisk-patched one plus a Magisk overlay.d init script that, on this boot
# only, installs the build host's ADB key (~/.android/adbkey.pub) and turns ADB on — so a fresh
# install that crashes during setup can be read with `adb logcat`.
#
#   ./steps/debug-boot.sh <signed dir>          build <signed dir>/../debug/init_boot-debug.img
#   ./steps/debug-boot.sh <signed dir> flash    + wipe /data, flash it, boot, stream logcat
#
# Only for an UNLOCKED phone (the image no longer matches our AVB chain → orange
# state). Never ship it; reflash the real init_boot (or `flash.sh flash`) afterwards.
# Used 2026-11-14 to find the SystemUI / mac_permissions boot loop.
set -euo pipefail
cd "$(dirname "$0")/.."
. steps/lib.sh 2>/dev/null || {
  ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
  fail() { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }
}
d=$(realpath "${1:?usage: $0 <signed dir> [flash]}"); mode=${2:-build}
img=$(ls "$d"/*-signed-img.zip); out=$(realpath "$d/..")/debug
[ -f ~/.android/adbkey.pub ] || fail "no ~/.android/adbkey.pub (run adb once)"
magisk=${MAGISK_APK:-$HOME/phone/rango/Magisk-v31.1.apk}
container=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^lineage-sign:' | head -1)
[ -n "$container" ] || fail "no lineage-sign image (run steps/sign.sh once)"

in=$(mktemp -d); trap 'rm -rf "$in"' EXIT
mkdir -p "$out"
unzip -p "$img" init_boot.img > "$in/init_boot.img"
cp ~/.android/adbkey.pub "$in/adb_keys"; cp "$magisk" "$in/Magisk.apk"
cat > "$in/debug.rc" <<'EOF'
on post-fs-data
    mkdir /data/misc/adb 02750 system shell
    copy ${MAGISKTMP}/adb_keys /data/misc/adb/adb_keys
    chown system shell /data/misc/adb/adb_keys
    chmod 0640 /data/misc/adb/adb_keys
    restorecon /data/misc/adb/adb_keys

on zygote-start
    setprop persist.sys.usb.config adb
    setprop sys.usb.config adb
EOF
cat > "$in/run.sh" <<'EOF'
set -e
cd /work && unzip -q /in/Magisk.apk lib/x86_64/libmagiskboot.so && cp lib/x86_64/libmagiskboot.so magiskboot && chmod +x magiskboot
cp /in/init_boot.img ib.img && ./magiskboot unpack ib.img >/dev/null
st=0; ./magiskboot cpio ramdisk.cpio test || st=$?   # 0 = stock, 1 = Magisk-patched
[ "$st" = 1 ] || { echo "init_boot is not Magisk-patched (built with MAGISK=0?)"; exit 1; }
./magiskboot cpio ramdisk.cpio "mkdir 0750 overlay.d" "mkdir 0750 overlay.d/sbin" \
  "add 0644 overlay.d/debug.rc /in/debug.rc" "add 0644 overlay.d/sbin/adb_keys /in/adb_keys"
./magiskboot repack ib.img /out/init_boot-debug.img >/dev/null
EOF
docker run --rm --platform linux/amd64 -v /nix/store:/nix/store:ro -v /run/binfmt:/run/binfmt:ro \
  -v "$in":/in:ro -v "$out":/out "$container" bash /in/run.sh || fail "building the debug init_boot"
ok "debug init_boot: $out/init_boot-debug.img"
[ "$mode" = flash ] || exit 0

[ "$(fastboot devices | wc -l)" = 1 ] || fail "phone not in fastboot (exactly one)"
[ "$(fastboot getvar unlocked 2>&1 | sed -n 's/^unlocked: //p')" = yes ] || fail "bootloader locked — debug boot only works unlocked"
read -rp "This WIPES the phone's data. Type 'wipe' to go on: " a; [ "$a" = wipe ] || fail "stopped"
fastboot -w; fastboot flash init_boot "$out/init_boot-debug.img"; fastboot reboot
log=$out/logcat-$(date +%F-%H%M).txt
echo "waiting for ADB; logcat → $log (Ctrl+C to stop)"
adb wait-for-device
until adb logcat -b main,system,crash -v threadtime >> "$log"; do adb wait-for-device; done
