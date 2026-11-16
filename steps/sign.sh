#!/usr/bin/env bash
# Sign a build at home, with our keys, Magisk in init_boot.
#   ./steps/sign.sh <build dir with target_files + otatools.zip> [keys dir]
# Runs Android's x86-64 otatools in an x86-64 Ubuntu container under QEMU
# emulation (NixOS: boot.binfmt.emulatedSystems = [ "x86_64-linux" ]); rootless Docker. Output in
# <build dir>/signed/. MAGISK=0 skips root. VBMETA_ONLY=1 re-does only vbmeta of
# <build dir>/signed (firmware descriptors) → <build dir>/signed-vbmeta/. Keys are mounted read-only and
# never copied anywhere.
set -euo pipefail
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }
cd "$(dirname "$0")/.."
. "$(dirname "$0")/../.local.env" 2>/dev/null || true  # SIGN_HOST=<machine with the keys>, untracked
[ -z "${SIGN_HOST:-}" ] || [ "$(cat /proc/sys/kernel/hostname)" = "$SIGN_HOST" ] || fail "run this on $SIGN_HOST (.local.env)"
[ -e /proc/sys/fs/binfmt_misc/x86_64-linux ] || fail "no x86-64 emulation (NixOS: boot.binfmt.emulatedSystems = [ "x86_64-linux" ])"
b=$(realpath "${1:?usage: $0 <build dir> [keys dir]}")
# before the YubiKey and the long run: the build must carry our root-image /
# system extras (a dropped PRODUCT_COPY_FILES rule would only show on the phone)
if [ "${VBMETA_ONLY:-0}" != 1 ]; then
  tfl=$(unzip -Z1 "$(ls "$b"/*-target_files*.zip | head -1)") || fail "can't list the target-files"
  for f in ROOT/nix/README ROOT/usr/bin/README SYSTEM/etc/resolv.conf SYSTEM/etc/init/nix.rc; do
    grep -qx "$f" <<<"$tfl" || fail "target-files lack $f (extras/extras.mk)"
  done
  ok "extras present: /nix, /usr/bin mountpoints, /etc/resolv.conf, /dev/shm init rule"
fi
# keys: a directory (test keys), or by default ~/lineage-keys.age — encrypted to
# the YubiKey (steps/keys-to-yubikey.sh), decrypted into RAM (/dev/shm) for this
# run only: YubiKey + PIV PIN + touch
keys=${2:-}
if [ -z "$keys" ] && [ ! -d "$HOME/lineage-keys" ] && [ -f "$HOME/lineage-keys.age" ]; then
  pkg() { nix build --no-link --print-out-paths --inputs-from "$(dirname "$0")/.." "nixpkgs#$1"; }
  export PATH=$(pkg age)/bin:$(pkg age-plugin-yubikey)/bin:$PATH
  ram=$(mktemp -d /dev/shm/lineage-keys.XXXXXX); chmod 700 "$ram"
  trap 'rm -rf "$ram"' EXIT
  echo "Unlocking the signing keys with the YubiKey: PIV PIN, then touch."
  age -d -i "$HOME/.config/lineage-rango/age-yubikey-identity.txt" "$HOME/lineage-keys.age" | tar -C "$ram" -xf - || fail "could not decrypt the keys"
  keys=$ram/lineage-keys
fi
keys=$(realpath "${keys:-$HOME/lineage-keys}")
[ -f "$keys/avb.pem" ] && [ -f "$keys/releasekey.pk8" ] || fail "no keys in $keys (steps/keys-create.sh)"
ls "$b"/*-target_files*.zip >/dev/null && [ -f "$b/otatools.zip" ] || fail "need target-files + otatools.zip in $b"
in=$(mktemp -d); trap 'rm -rf "$in" ${ram:+"$ram"}' EXIT
if [ "${VBMETA_ONLY:-0}" = 1 ]; then
  # re-do only vbmeta of <build>/signed (adds the bootloader firmware descriptors the
  # Pixel 10 needs before it locks) → <build>/signed-vbmeta; minutes, not hours
  src=$(ls "$b"/signed/*-signed-target_files.zip) || fail "no $b/signed/*-signed-target_files.zip"
  out=$b/signed-vbmeta; mkdir -p "$out" && [ -z "$(ls -A "$out")" ] || fail "$out is not empty"
  ln "$src" "$b/otatools.zip" "$in/" 2>/dev/null || cp "$src" "$b/otatools.zip" "$in/"
else
  out=$b/signed; mkdir -p "$out" && [ -z "$(ls -A "$out")" ] || fail "$out is not empty"
  ln "$b"/*-target_files*.zip "$b/otatools.zip" "$in/" 2>/dev/null || cp "$b"/*-target_files*.zip "$b/otatools.zip" "$in/"
  if [ "${MAGISK:-1}" = 1 ]; then cp "${MAGISK_APK:-$HOME/phone/rango/Magisk-v31.1.apk}" "$in/Magisk.apk"; fi
fi
# x86-64 Ubuntu (same pinned digest as the build container) + tools/sign-packages.txt.
# Made with run + commit, not `docker build`: build steps can't get the
# /nix/store + /run/binfmt mounts the (dynamic) QEMU emulator needs.
base=docker.io/library/ubuntu:24.04@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5
emu=(-v /nix/store:/nix/store:ro -v /run/binfmt:/run/binfmt:ro)
# packages from a dated Ubuntu snapshot (same as vm/Containerfile)
snap=$(sed -n 's/^ARG APT_SNAPSHOT=//p' vm/Containerfile)
img=lineage-sign:$(printf '%s\n' "$base" "$snap" "$(cat tools/sign-packages.txt)" | sha256sum | cut -c1-12)
if ! docker image inspect "$img" >/dev/null 2>&1; then
  echo "creating $img (apt under emulation, a few minutes)"
  docker rm -f lineage-sign-prep >/dev/null 2>&1 || true
  docker run --name lineage-sign-prep --platform linux/amd64 "${emu[@]}" -e DEBIAN_FRONTEND=noninteractive "$base" \
    bash -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null && apt-get update -qq --snapshot $snap && apt-get install --snapshot $snap -y -qq --no-install-recommends $(tr '\n' ' ' < tools/sign-packages.txt) >/dev/null && rm -rf /var/lib/apt/lists/*" \
    || fail "signing image"
  docker commit --change 'ENV LC_ALL=C.UTF-8' --change 'WORKDIR /work' lineage-sign-prep "$img" >/dev/null && docker rm lineage-sign-prep >/dev/null
fi
docker run --rm --platform linux/amd64 "${emu[@]}" -e VBMETA_ONLY="${VBMETA_ONLY:-0}" \
  --tmpfs /k:rw,noexec,nosuid,size=64m,mode=0700 \
  -v "$in":/in:ro -v "$keys":/keys:ro -v "$out":/out -v "$PWD/tools/sign-inner.sh":/sign-inner.sh:ro -v "$PWD/tools/check-mac-certs.py":/check-mac-certs.py:ro -v "$PWD/tools/check-otacerts.py":/check-otacerts.py:ro \
  "$img" bash /sign-inner.sh 2>&1 | tee "$out.log" || fail "signing failed (log: $out.log)"
# step times ("=== HH:MM:SS step") stay in <build>/signed.log (2026-11-16) — real numbers
# if signing time ever needs optimising (decided then: not worth changing the path)
ok "signed build in $out (log: $out.log)"; cat "$out/SHA256SUMS"
