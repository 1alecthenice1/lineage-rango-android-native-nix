#!/usr/bin/env bash
# Move the signing keys from plaintext ~/lineage-keys to ~/lineage-keys.age,
# encrypted to an age identity ON THE YUBIKEY (age-plugin-yubikey, a retired PIV
# slot — slot 9C with the Secure Boot keys is not touched). Afterwards every
# signing run needs the YubiKey + PIV PIN + touch; steps/sign.sh decrypts the
# keys into RAM only. The passphrase backup (~/lineage-keys-<date>.tar.age, card,
# offsite storage) stays the disaster copy if the YubiKey is lost.
#   ./steps/keys-to-yubikey.sh
# PIV PIN: only 3 tries (then PUK, 3 tries; a PIV reset would ERASE slot 9C).
set -euo pipefail
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }
. "$(dirname "$0")/../.local.env" 2>/dev/null || true  # SIGN_HOST=<machine with the keys>, untracked
[ -z "${SIGN_HOST:-}" ] || [ "$(cat /proc/sys/kernel/hostname)" = "$SIGN_HOST" ] || fail "run this on $SIGN_HOST (.local.env)"
KEYS=${KEYS:-$HOME/lineage-keys}
OUT=${OUT:-$HOME/lineage-keys.age}
IDDIR=$HOME/.config/lineage-rango; ID=$IDDIR/age-yubikey-identity.txt
SLOT=${SLOT:-1}   # age-plugin-yubikey slot numbers 1..20 = PIV retired slots 82..95
[ -f "$KEYS/avb.pem" ] || fail "no keys in $KEYS"
[ -e "$OUT" ] && fail "$OUT exists already"
pkg() { nix build --no-link --print-out-paths --inputs-from "$(dirname "$0")/.." "nixpkgs#$1"; }
export PATH=$(pkg age)/bin:$(pkg age-plugin-yubikey)/bin:$PATH
ykman list >/dev/null 2>&1 && [ -n "$(ykman list)" ] || fail "no YubiKey plugged in"

mkdir -p "$IDDIR"; chmod 700 "$IDDIR"
if [ ! -s "$ID" ]; then
  echo "Creating the age key on the YubiKey (slot $SLOT): PIV PIN once, then touch when it blinks."
  age-plugin-yubikey --generate --slot "$SLOT" --name lineage-rango-keys \
    --pin-policy once --touch-policy always > "$ID" || fail "generate"
fi
R=$(sed -n 's/^#[[:space:]]*[Rr]ecipient:[[:space:]]*//p' "$ID" | head -1)
[ -n "$R" ] || fail "no recipient in $ID"
ok "YubiKey identity (stub, not secret): $ID"; echo "   recipient: $R"

tar -C "$(dirname "$KEYS")" -cf - "$(basename "$KEYS")" | age -r "$R" -o "$OUT.tmp" || fail "encrypt"
mv "$OUT.tmp" "$OUT"; chmod 600 "$OUT"
ok "encrypted: $OUT ($(du -h "$OUT" | cut -f1))"

echo "Checking it decrypts with the YubiKey: PIN, then touch."
chk=$(mktemp -d /dev/shm/lineage-keys-check.XXXXXX); trap 'rm -rf "$chk"' EXIT
age -d -i "$ID" "$OUT" | tar -C "$chk" -xf - || fail "decrypt check"
diff -r "$KEYS" "$chk/$(basename "$KEYS")" >/dev/null || fail "decrypted copy differs!"
ok "decrypts and matches the plaintext keys byte for byte"

echo
echo "Delete the plaintext $KEYS now? (the encrypted file + the passphrase backup remain)"
read -rp "Type 'delete' to delete, anything else to keep it: " a
if [ "$a" = delete ]; then
  rm -rf "$KEYS" && ok "plaintext keys deleted"
  echo "Note: /home snapshots (snapper) taken since the keys were created still contain them;"
  echo "      list with: snapper -c home list"
else
  echo "kept $KEYS"
fi
