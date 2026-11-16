#!/usr/bin/env bash
# Flash a signed build onto rango and relock the bootloader with OUR AVB key.
#   ./steps/flash.sh check  <signed dir>   offline, no phone: checksums, whole AVB chain
#                                          verified, every key = ours, firmware versions
#   ./steps/flash.sh flash  <signed dir>   phone in fastboot, UNLOCKED: our key into
#                                          avb_custom_key + all images — WIPES the phone
#   ./steps/flash.sh verify <signed dir>   phone booted, USB debugging on: the vbmeta it
#                                          booted = ours, OEM unlocking still allowed
#   ./steps/flash.sh lock   <signed dir>   phone in fastboot: relock — WIPES again; only
#                                          after verify passed for this build
# <signed dir> = output of steps/sign.sh (…/signed with *-img.zip, avb_pkmd.bin, SHA256SUMS).
#
# Why the order: a locked bootloader boots only images signed by the key in
# avb_custom_key. Relocking onto images that don't verify = no bootable OS; the
# way back is `fastboot flashing unlock`, which needs "OEM unlocking" ON in
# Developer options — so it stays on (checked before locking), and we lock only
# after the phone has booted exactly these images.
# Firmware (bootloader, modem, …) is NOT flashed: the img zip has none. It must
# already match the build (checked); the official LineageOS install set it.
set -euo pipefail
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }
cd "$(dirname "$0")/.."
repo=$PWD
mode=${1:-}; d=$(realpath "${2:?usage: $0 check|flash|verify|lock <signed dir>}")
[ -f "$d/SHA256SUMS" ] && [ -f "$d/avb_pkmd.bin" ] || fail "$d: no SHA256SUMS / avb_pkmd.bin (steps/sign.sh output?)"
img=$(ls "$d"/*-signed-img.zip); tf=$(ls "$d"/*-signed-target_files.zip)
avb=$d/.avb   # extracted AVB images (small ones kept for verify), check results
pkg() { nix build --no-link --print-out-paths --inputs-from "$(dirname "$0")/.." "nixpkgs#$1"; }
avbtool() { PATH=$(pkg openssl.bin)/bin:$PATH "$(pkg python3)/bin/python3" -I "$repo/tools/avbtool.py" "$@"; }
pk_sha1=$(sha1sum < "$d/avb_pkmd.bin" | cut -d' ' -f1)
pk_sha256=$(sha256sum < "$d/avb_pkmd.bin" | cut -d' ' -f1)
sums=$(sha256sum < "$d/SHA256SUMS" | cut -d' ' -f1)   # identifies this exact build

# firmware the build was made for (from its target-files)
# first matching line; reads all input (grep -m1 would SIGPIPE unzip under pipefail → exit 141)
first() { awk -v re="$1" '!f && $0 ~ re { print; f = 1 }'; }
fw_expected() {
  bl=$(unzip -p "$tf" RADIO/abl.img | strings | first '^[a-z]+-[0-9.]+-[0-9]+$' | sed 's/^[a-z]*-//')
  bb=$(unzip -p "$tf" RADIO/modem.img | strings | first '^g[0-9]+[a-z]?-[0-9-]+-[A-Z]-[0-9]+$')
  [ -n "$bl" ] && [ -n "$bb" ] || fail "could not read firmware versions from the target-files"
}
need_checked() { [ "$(cat "$avb/checked" 2>/dev/null)" = "$sums" ] || fail "run '$0 check $d' first (for this build)"; }
one_fastboot() {
  [ "$(fastboot devices | wc -l)" = 1 ] || fail "need exactly one phone in fastboot (adb reboot bootloader)"
  [ "$(fastboot getvar product 2>&1 | sed -n 's/^product: //p')" = rango ] || fail "not a rango"
}
fbvar() { fastboot getvar "$1" 2>&1 | sed -n "s/^$1: //p"; }
one_adb() {
  [ "$(adb devices | grep -c 'device$')" = 1 ] || fail "need exactly one phone on adb (USB debugging on, authorised)"
  [ "$(adb shell getprop ro.product.device | tr -d '\r')" = rango ] || fail "not a rango"
}
prop() { adb shell getprop "$1" | tr -d '\r'; }

case "$mode" in
check)
  (cd "$d" && sha256sum --quiet -c SHA256SUMS) || fail "checksums"; ok "checksums"
  # SELinux cert tables must name our keys, not the test keys (else SystemUI etc. lose
  # their domains and a fresh install boot-loops into recovery, 2026-11-14)
  "$(pkg python3)/bin/python3" -I "$repo/tools/check-mac-certs.py" "$tf" "$d/../otatools.zip" || fail "SELinux mac_permissions still name test certs — re-sign"
  # every otacerts.zip: only our release cert, no duplicate entries (a duplicate makes
  # recovery reject the file → no sideload/OTA possible, builds 7 + 9, 2026-11-15)
  "$(pkg python3)/bin/python3" -I "$repo/tools/check-otacerts.py" "$tf" "$repo/keys-public/releasekey.x509.pem" || fail "otacerts.zip broken — recovery would refuse every update; re-sign"
  ok "otacerts: recovery + system accept only our key"
  rm -rf "$avb"; mkdir -p "$avb/all"
  echo "extracting images (~5 GB, removed again after the check)…"
  unzip -q -o "$img" -d "$avb/all"
  [ "$(unzip -p "$img" android-info.txt)" = "require board=rango" ] || fail "android-info.txt is not for rango"
  echo "verifying the AVB chain: every signature, hash and hashtree (a few minutes)…"
  avbtool verify_image --image "$avb/all/vbmeta.img" --follow_chain_partitions > "$avb/verify.txt" 2>&1 \
    || { tail -5 "$avb/verify.txt"; fail "AVB verification failed"; }
  ok "AVB chain verifies ($(grep -c 'Successfully verified' "$avb/verify.txt") images/descriptors)"
  # every key in the chain must be ours: vbmeta's own, each chain descriptor, each chained image
  keys=$(for i in "$avb"/all/vbmeta*.img "$avb"/all/boot.img "$avb"/all/init_boot.img; do
           avbtool info_image --image "$i" | sed -n 's/.*Public key (sha1): *//p'; done | sort | uniq -c)
  echo "$keys"
  [ "$(echo "$keys" | wc -l)" = 1 ] && echo "$keys" | grep -q " $pk_sha1$" || fail "a key in the chain is not ours ($pk_sha1)"
  ok "all AVB keys = ours (sha1 $pk_sha1)"
  avbtool info_image --image "$avb/all/vbmeta.img" | grep -q 'Algorithm: *SHA256_RSA4096' || fail "vbmeta not SHA256_RSA4096"
  flags=$(avbtool info_image --image "$avb/all/vbmeta.img" | sed -n 's/^Flags: *//p')
  [ "$flags" = 0 ] || fail "vbmeta flags $flags (verity/verification disabled?)"
  ok "vbmeta: SHA256_RSA4096, flags 0 (verification + dm-verity on)"
  avbtool info_image --image "$avb/all/vbmeta.img" > "$avb/vbmeta-info.txt"
  "$(pkg python3)/bin/python3" -I "$repo/tools/check-fw-descriptors.py" "$avb/vbmeta-info.txt" "$tf" \
    || fail "vbmeta lacks the firmware descriptors — the bootloader would refuse to lock (VBMETA_ONLY=1 steps/sign.sh)"
  # small images kept for `verify` (vbmeta digest over the chain)
  for i in vbmeta vbmeta_system vbmeta_vendor boot init_boot vendor_boot vendor_kernel_boot dtbo pvmfw; do
    [ -f "$avb/all/$i.img" ] && mv "$avb/all/$i.img" "$avb/"; done
  rm -rf "$avb/all"
  fw_expected; echo "$bl" > "$avb/bootloader"; echo "$bb" > "$avb/baseband"
  ok "build firmware: bootloader $bl, baseband $bb"
  echo "$sums" > "$avb/checked"
  ok "check passed — next: phone in fastboot, '$0 flash $d'" ;;

flash)
  need_checked; one_fastboot
  [ "$(fbvar unlocked)" = yes ] || fail "bootloader is locked — flashing a new key needs it unlocked"
  hbl=$(fbvar version-bootloader); hbl=${hbl#*-}; hbb=$(fbvar version-baseband)  # phone: "deepspace-17.4-…"
  [ "$hbl" = "$(cat "$avb/bootloader")" ] || fail "phone bootloader $hbl ≠ build's $(cat "$avb/bootloader") — flash the matching firmware first"
  [ "$hbb" = "$(cat "$avb/baseband")" ] || fail "phone baseband $hbb ≠ build's $(cat "$avb/baseband") — flash the matching firmware first"
  ok "firmware matches the build ($hbl / $hbb), slot $(fbvar current-slot)"
  warn "This ERASES everything on the phone and installs $(basename "$img")."
  read -rp "Type 'wipe' to go on: " a; [ "$a" = wipe ] || fail "stopped"
  fastboot erase avb_custom_key
  fastboot flash avb_custom_key "$d/avb_pkmd.bin"
  ok "our AVB key is in avb_custom_key (sha256 $pk_sha256)"
  fastboot -w update "$img"
  ok "flashed; the phone reboots into setup (orange 'unlocked' warning is expected now)"
  echo "Next: quick setup (no accounts needed — locking wipes again), Developer options →"
  echo "USB debugging on, then '$0 verify $d'." ;;

verify)
  need_checked; one_adb
  want=$(avbtool calculate_vbmeta_digest --image "$avb/vbmeta.img" --hash_algorithm sha256)
  got=$(prop ro.boot.vbmeta.digest); state=$(prop ro.boot.verifiedbootstate)
  echo "booted: $(prop ro.build.fingerprint)"
  echo "        LineageOS $(prop ro.lineage.version), verified boot state $state, locked $(prop ro.boot.flash.locked)"
  if [ -n "$got" ]; then
    # every partition the bootloader hashed must match our descriptor — the vbmeta
    # digest alone doesn't cover the images, and an unlocked phone boots stale ones
    # anyway (2026-11-14: init_boot/vendor_boot/pvmfw were still the UNSIGNED build's)
    ours=$(for i in vbmeta boot init_boot vbmeta_system vbmeta_vendor; do avbtool info_image --image "$avb/$i.img"; done \
           | awk '/Partition Name:/ { p = $3 } /Digest:/ { print p, $2 }')
    pd=$(adb shell getprop | tr -d '\r' | sed -n 's/^\[ro\.boot\.vbmeta\.\([a-z0-9_]*\)\.digest\]: \[\(.*\)\]$/\1 \2/p' | grep -v '^public_key ')
    [ "$(wc -l <<<"$pd")" -ge 10 ] || fail "the bootloader reported only $(wc -l <<<"$pd") partition digests"
    bad=0
    while read -r p dg; do
      o=$(awk -v p="$p" '$1 == p { print $2; exit }' <<<"$ours")
      if [ "$o" = "$dg" ]; then echo "  ✓ $p"; else echo "  ✗ $p: phone ${dg:0:16}… ≠ ours ${o:0:16}…"; bad=1; fi
    done <<<"$pd"
    [ "$bad" = 0 ] || fail "partitions on the phone are not this build's — reflash ('$0 flash $d')"
    ok "every partition the bootloader hashed = this build ($(wc -l <<<"$pd"))"
    [ "$(prop ro.boot.vbmeta.public_key_digest)" = "$pk_sha256" ] || fail "vbmeta key on the phone is not ours"
    [ "$got" = "$want" ] || fail "booted vbmeta digest $got ≠ ours $want"
    ok "the phone booted exactly our vbmeta chain ($want), key $pk_sha256"
  else
    # rango's bootloader (17.4) passes no ro.boot.vbmeta.* at all (2026-11-14) → match the
    # build identity instead; the chain itself was verified offline by 'check', and a
    # locked bootloader boots nothing that isn't signed with our key
    bp=$(unzip -p "$tf" SYSTEM/build.prop)
    for k in ro.system.build.fingerprint ro.system.build.date.utc; do
      w=$(printf '%s\n' "$bp" | sed -n "s/^$k=//p")
      [ -n "$w" ] && [ "$(prop "$k")" = "$w" ] || fail "booted $k '$(prop "$k")' ≠ this build's '$w'"
    done
    ok "booted system = this build ($(prop ro.system.build.date.utc), $(prop ro.system.build.fingerprint | cut -d: -f2))"
    echo "  (no ro.boot.vbmeta.digest from this bootloader — chain verified offline by 'check')"
  fi
  case "$state" in
  orange)
    # sys.oem_unlock_allowed stays empty while unlocked (the switch is greyed out);
    # the bootloader's get_unlock_ability is authoritative — 'lock' checks it in fastboot
    echo "  OEM unlocking: checked by 'lock' in fastboot (get_unlock_ability must be 1)"
    echo "$sums" > "$avb/verified"
    ok "ready to lock — adb reboot bootloader, then '$0 lock $d'" ;;
  yellow)
    [ "$(prop ro.boot.flash.locked)" = 1 ] || fail "yellow but not locked?"
    ok "LOCKED with our key (yellow = custom key) — done. Keep OEM unlocking on." ;;
  *) fail "unexpected verified boot state '$state'" ;;
  esac ;;

lock)
  [ "$(cat "$avb/verified" 2>/dev/null)" = "$sums" ] || fail "'$0 verify $d' has not passed for this build"
  one_fastboot
  [ "$(fbvar unlocked)" = yes ] || fail "already locked"
  fastboot flashing get_unlock_ability 2>&1 | grep -q 'get_unlock_ability: 1' || fail "unlock ability is 0 — OEM unlocking must be ON before locking"
  ok "unlock ability 1 (the way back stays open)"
  echo "After locking, the boot screen shows a yellow warning with the key's ID;"
  echo "ours is sha256 $pk_sha256 (compare the characters shown)."
  warn "Locking ERASES the phone again."
  read -rp "Type 'lock' to go on: " a; [ "$a" = lock ] || fail "stopped"
  fastboot flashing lock
  ok "confirm on the phone (volume keys + power). Then set up, USB debugging on, '$0 verify $d'." ;;

*) fail "usage: $0 check|flash|verify|lock <signed dir>" ;;
esac
