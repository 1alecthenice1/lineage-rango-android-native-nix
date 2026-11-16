#!/usr/bin/env bash
# Create the signing keys for our LineageOS builds — ONCE, on the build host, before the
# first flash. Never on the build VM, never in a git repo.
#   ./steps/keys-create.sh <target-files.zip>      (the build's APEX list)
#   KEYS=… SUBJECT=… ./steps/keys-create.sh …       (overrides)
# Creates in $KEYS (default ~/lineage-keys, 0700):
#   APK keys     releasekey platform shared media networkstack nfc bluetooth
#                sdk_sandbox cyngn-app  (*.pk8 + *.x509.pem, RSA 4096)
#   APEX keys    one container cert + one payload key (*.pem) per APEX the
#                build signs itself (META/apexkeys.txt minus PRESIGNED = Google's)
#   AVB          avb.pem (RSA 4096) + avb_pkmd.bin (public key for
#                `fastboot flash avb_custom_key`, i.e. what the relocked phone trusts)
# then an age-encrypted backup (passphrase you choose), copied to $BACKUP_DIR if
# set (e.g. an offline card). Keep the plain ~/lineage-keys out of regular backups.
# Losing the keys = no more updates without wiping the phone.
set -euo pipefail
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }
cd "$(dirname "$0")/.."
. "$(dirname "$0")/../.local.env" 2>/dev/null || true  # SIGN_HOST=<machine with the keys>, untracked
[ -z "${SIGN_HOST:-}" ] || [ "$(cat /proc/sys/kernel/hostname)" = "$SIGN_HOST" ] || fail "run this on $SIGN_HOST (.local.env)"
tf=${1:?usage: $0 <target-files.zip>}
[ -s "$tf" ] || fail "no target-files: $tf"
KEYS=${KEYS:-$HOME/lineage-keys}
# certificate subject: visible to anyone who inspects an APK signature, so
# nothing personal in it
SUBJECT=${SUBJECT:-/C=US/O=lineage-rango/OU=release/CN=lineage-rango}
[ -e "$KEYS" ] && fail "$KEYS exists — refusing to overwrite keys (move it away deliberately if you really mean it)"
pkg() { nix build --no-link --print-out-paths --inputs-from "$(dirname "$0")/.." "nixpkgs#$1"; }
openssl=$(pkg openssl.bin)/bin/openssl
unzip=$(pkg unzip)/bin/unzip

umask 077
mkdir -p "$KEYS"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# like AOSP development/tools/make_key, unencrypted (signing runs unattended;
# protection = disk encryption on the signing host + encrypted backups)
make_key() {
  local name=$1
  "$openssl" genrsa -out "$tmp/$name.pem" 4096 2>/dev/null
  "$openssl" req -new -x509 -sha256 -key "$tmp/$name.pem" -out "$KEYS/$name.x509.pem" -days 10000 -subj "$SUBJECT"
  "$openssl" pkcs8 -in "$tmp/$name.pem" -topk8 -outform DER -out "$KEYS/$name.pk8" -nocrypt
  rm -f "$tmp/$name.pem"
}

for k in releasekey platform shared media networkstack nfc bluetooth sdk_sandbox cyngn-app; do
  make_key "$k"
done
ok "APK keys"

"$unzip" -p "$tf" META/apexkeys.txt > "$tmp/apexkeys.txt" || fail "no META/apexkeys.txt in $tf"
grep -v 'PRESIGNED' "$tmp/apexkeys.txt" | grep -o '^name="[^"]*"' | sed 's/^name="//; s/"$//; s/\.c\?apex$//' | sort -u > "$KEYS/apex-list.txt"
while read -r a; do
  make_key "$a"                                            # container certificate
  "$openssl" genrsa -out "$KEYS/$a.pem" 4096 2>/dev/null   # payload (AVB) key
done < "$KEYS/apex-list.txt"
ok "APEX keys: $(wc -l < "$KEYS/apex-list.txt") (Google's $(grep -c PRESIGNED "$tmp/apexkeys.txt") presigned ones keep Google's signatures)"

"$openssl" genrsa -out "$KEYS/avb.pem" 4096 2>/dev/null
PATH="$(dirname "$openssl"):$PATH" python3 tools/avbtool.py extract_public_key --key "$KEYS/avb.pem" --output "$KEYS/avb_pkmd.bin"   # avbtool runs openssl by name
ok "AVB key + avb_pkmd.bin"

chmod 700 "$KEYS"; chmod 600 "$KEYS"/*
{ echo "created $(date -u +%FT%TZ) on $(hostname), subject $SUBJECT"
  for k in releasekey platform; do echo "$k cert sha256: $("$openssl" x509 -in "$KEYS/$k.x509.pem" -noout -fingerprint -sha256 | cut -d= -f2)"; done
  echo "avb_pkmd.bin sha256: $(sha256sum "$KEYS/avb_pkmd.bin" | cut -d' ' -f1)"
} | tee "$KEYS/FINGERPRINTS.txt"

[ "${NO_BACKUP:-}" = 1 ] && { echo "NO_BACKUP=1: skipping the backup (test run)"; exit 0; }
age=$(pkg age)/bin/age
out=$HOME/lineage-keys-$(date +%F).tar.age
echo "Choose a passphrase for the key backup (asked twice). Keep it in a password manager AND on paper."
tar -C "$(dirname "$KEYS")" -cf - "$(basename "$KEYS")" | "$age" -p -o "$out" || fail "backup encryption"
echo "Checking the backup: enter the same passphrase once more."
"$age" -d "$out" | tar -tf - | grep -q 'avb.pem$' || fail "backup check failed"
ok "backup $out ($(du -h "$out" | cut -f1)) decrypts and contains the keys"
card=${BACKUP_DIR:-}
if [ -n "$card" ] && [ -d "$card" ]; then
  cp "$out" "$card/" && sync && cmp "$out" "$card/$(basename "$out")" && ok "copied to $card/"
else
  echo "Store $out somewhere offline and offsite (BACKUP_DIR=<dir> copies it there)."
fi
