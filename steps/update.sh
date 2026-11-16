#!/usr/bin/env bash
# Install a newer signed build on the (locked) phone — no update server, no wipe.
# Only OTAs signed with our release key are accepted; the OTA already contains the
# init_boot sign.sh produced (Magisk-patched unless MAGISK=0).
#   ./steps/update.sh <signed dir>            sideload from recovery (adb sideload)
#   ./steps/update.sh local <signed dir>      copy the OTA to the phone's Download
#                                             folder for Settings → System → Updater
#                                             → ⋮ → Local update (no recovery involved)
#   ./steps/update.sh verify <signed dir>     after the reboot: did exactly this build boot?
# Phone: booted, USB debugging on, on the build host's USB-A port.
# Background (2026-11-15): builds 7 + 9 (first signing) had a broken recovery
# otacerts.zip (duplicate entry) → recovery refused every sideload; the Updater
# route checks against SYSTEM's otacerts instead and still worked.
set -euo pipefail
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }
cd "$(dirname "$0")/.."
mode=sideload
case "${1:-}" in local|verify|sideload) mode=$1; shift ;; esac
d=$(realpath "${1:?usage: $0 [sideload|local|verify] <signed dir>}")
ota=$(ls "$d"/*-signed-ota.zip) || fail "no *-signed-ota.zip in $d"
# flash.sh check extracts the AVB images we compare against after the reboot
[ -f "$d/.avb/vbmeta.img" ] || fail "run './steps/flash.sh check $d' first"
pkg() { nix build --no-link --print-out-paths --inputs-from "$(dirname "$0")/.." "nixpkgs#$1"; }
want=$(PATH=$(pkg openssl.bin)/bin:$PATH "$(pkg python3)/bin/python3" -I tools/avbtool.py \
  calculate_vbmeta_digest --image "$d/.avb/vbmeta.img" --hash_algorithm sha256)
prop() { adb shell getprop "$1" | tr -d '\r'; }
state() { echo "$(prop ro.build.fingerprint) ($(prop ro.boot.verifiedbootstate), $(prop ro.boot.vbmeta.device_state), slot $(prop ro.boot.slot_suffix), built $(prop ro.build.date))"; }
phone() {
  [ "$(adb devices | grep -c 'device$')" = 1 ] || fail "need exactly one booted phone on adb"
  [ "$(prop ro.product.device)" = rango ] || fail "not a rango"
}
# USB link speed (Mbit/s) of the Google device: after a reboot from recovery it once
# came up as full speed (12M, "not running at top speed") and stayed so — the 1.9 GB
# copy then took 30 min at 1 MB/s instead of ~1 min (2026-11-15)
usb_speed() {
  local d
  for d in /sys/bus/usb/devices/*; do
    [ "$(cat "$d/idVendor" 2>/dev/null)" = 18d1 ] && { cat "$d/speed"; return; }
  done
  echo 0
}
check_usb() {
  local s; s=$(usb_speed)
  [ "${s%%.*}" -ge 480 ] 2>/dev/null && return
  # phone-side gadget reset re-enumerates the link (tested on a real 12M case
  # 2026-11-16, after an Updater reboot: 12 → 480). NEVER usbreset on the build host's side —
  # that froze the build host (2026-11-15).
  echo "phone is at ${s} Mbit/s (USB 1.1 fallback) — resetting the phone's USB gadget…"
  adb shell svc usb resetUsbGadget >/dev/null 2>&1 || true   # exits 255 as adb drops: expected
  sleep 6; adb wait-for-device
  s=$(usb_speed)
  [ "${s%%.*}" -ge 480 ] 2>/dev/null && { ok "USB link back at ${s} Mbit/s"; return; }
  fail "phone still at ${s} Mbit/s — unplug and replug the cable (the build host's USB-A port), then rerun"
}
verify() {
  local got
  got=$(prop ro.boot.vbmeta.digest)
  echo "booted: $(state)"
  [ "$got" = "$want" ] || fail "booted vbmeta $got ≠ this build's $want (update not installed, or the phone fell back to the old slot)"
  ok "the phone runs this build (vbmeta $want)"
}
newer() {   # the OTA must not be older than what runs (Updater + recovery refuse older)
  local cur new
  cur=$(prop ro.build.date.utc)
  new=$(unzip -p "$ota" META-INF/com/android/metadata | sed -n 's/^post-timestamp=//p')
  [ -n "$new" ] || fail "no post-timestamp in the OTA metadata"
  if [ "$new" -lt "$cur" ]; then fail "OTA ($new) is older than the running build ($cur) — refused"; fi
  [ "$new" -gt "$cur" ] || echo "note: same build timestamp as the running build (reinstall of the same build)"
}

case "$mode" in
verify)
  phone
  [ "$(prop sys.boot_completed)" = 1 ] || fail "phone still booting"
  verify ;;
local)
  (cd "$d" && sha256sum --quiet -c SHA256SUMS) || fail "checksums"
  phone; newer; check_usb
  # name the copy after the build dir (e.g. lineage-rango-2026-11-16-build11-ota.zip):
  # every build's OTA is called lineage-rango-signed-ota.zip, and adb push keeps the build host's
  # mtime (UTC) → build 11 showed as "Nov 15" in the file picker (2026-11-16)
  dst=/sdcard/Download/lineage-rango-$(basename "$(dirname "$d")")-ota.zip
  echo "now:  $(state)"
  echo "copying $(basename "$ota") ($(du -h "$ota" | cut -f1)) to $dst …"
  adb push "$ota" "$dst" >/dev/null
  h_pc=$(sha256sum "$ota" | cut -d' ' -f1)
  h_ph=$(adb shell sha256sum "$dst" | tr -d '\r' | cut -d' ' -f1)
  [ "$h_pc" = "$h_ph" ] || fail "checksum on the phone differs ($h_ph) — copy again"
  ok "on the phone, checksum matches ($h_pc)"
  cat <<EOF
On the phone: Settings → System → Updater → ⋮ (top right) → Local update → Download →
$(basename "$ota") → confirm. It installs in the background into the other slot;
when it asks, reboot. Then: $0 verify $d
Afterwards delete the copy: adb shell rm '$dst'
EOF
  ;;
sideload)
  (cd "$d" && sha256sum --quiet -c SHA256SUMS) || fail "checksums"
  phone; newer
  echo "now:  $(state)"
  echo "new:  $(basename "$ota") ($(du -h "$ota" | cut -f1))"
  read -rp "Type 'update' to sideload it: " a; [ "$a" = update ] || fail "stopped"
  adb reboot sideload-auto-reboot
  echo "waiting for the phone in sideload mode…"
  until adb devices | grep -q 'sideload$'; do sleep 3; done
  # adb's exit code is 0 even when recovery rejects the package; a rejection shows up
  # as "Total xfer: 0.00x" (recovery stopped reading at once — signature/keys)
  out=$(adb sideload "$ota" 2>&1 | tee /dev/stderr) || fail "sideload failed (see the phone's screen)"
  if grep -q 'Total xfer: 0\.00x' <<<"$out"; then
    fail "recovery rejected the package right away (keys/signature). The phone reboots into the old build; details: recovery → Advanced → View recovery logs"
  fi
  ok "sideloaded — the phone reboots by itself"
  echo "waiting for the phone to boot (first boot after an update takes a while)…"
  adb wait-for-device
  until [ "$(prop sys.boot_completed)" = 1 ]; do sleep 5; done
  verify ;;
esac
