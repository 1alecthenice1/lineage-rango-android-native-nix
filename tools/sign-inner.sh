#!/usr/bin/env bash
# Runs INSIDE the x86-64 signing container (steps/sign.sh; Ubuntu 24.04 +
# tools/sign-packages.txt, under QEMU emulation). Mounts:
#   /in   target-files.zip, otatools.zip, Magisk.apk (read-only)
#   /keys signing keys (read-only)          /out  results
set -euo pipefail
step() { printf '\n=== %s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
W=/work
# otatools chmod()s key files while zipping them (WriteOtacerts → ZipWrite), so a
# read-only /keys fails: copy into /k, a RAM-only tmpfs (sign.sh --tmpfs), never
# onto the container's on-disk layer
cp -a /keys/. /k/ && K=/k
TF=$(ls /in/*-target_files*.zip | head -1)
mkdir -p $W/otatools && cd $W/otatools && unzip -q -o /in/otatools.zip
export PATH=$W/otatools/bin:$PATH
cd $W

# Bootloader firmware in vbmeta (2026-11-14): Google's stock vbmeta carries a hash
# descriptor for every firmware partition (abl, bl31, cap, cpm, dbc, dbl, dram_*, gc,
# gdmc, gsa_*, tzsw = every RADIO image except modem); LineageOS's has none, and the
# Pixel 10 bootloader then refuses `fastboot flashing lock` ("invalid android images,
# skip locking"). RADIO/ holds the exact factory firmware (digest checked against
# stock), so: unsigned hash footer on a copy of each → --include_descriptors_from_image.
fw_args=()
mkdir -p $W/fw
for n in $(unzip -Z1 "$TF" 'RADIO/*.img' | sed 's#^RADIO/##; s#\.img$##'); do
  [ "$n" = modem ] && continue
  unzip -p "$TF" "RADIO/$n.img" > "$W/fw/$n.img"
  avbtool add_hash_footer --image "$W/fw/$n.img" --partition_name "$n" --dynamic_partition_size --hash_algorithm sha256
  fw_args+=(--include_descriptors_from_image "$W/fw/$n.img")
done
[ "${#fw_args[@]}" -ge 40 ] || { echo "only $((${#fw_args[@]} / 2)) firmware images in RADIO/ (want 22)"; exit 1; }
echo "firmware hash descriptors for vbmeta: $(ls $W/fw | sed 's/\.img$//' | tr '\n' ' ')"

if [ "${VBMETA_ONLY:-0}" = 1 ]; then
# Re-do only vbmeta of an already SIGNED target-files (sign.sh VBMETA_ONLY=1): keep its
# descriptors (chains, boot/dtbo/vendor hashes, props), add the firmware ones, re-sign
# with our AVB key, same rollback index, flags 0. Chained partitions are untouched.
step "vbmeta only: add firmware descriptors to the signed vbmeta"
unzip -p "$TF" IMAGES/vbmeta.img > $W/old-vbmeta.img
info=$(avbtool info_image --image $W/old-vbmeta.img)
grep -q 'Algorithm: *SHA256_RSA4096' <<<"$info" || { echo "old vbmeta not SHA256_RSA4096"; exit 1; }
grep -q 'Partition Name: *abl$' <<<"$info" && { echo "vbmeta already has firmware descriptors"; exit 1; }
rbi=$(echo "$info" | sed -n 's/^Rollback Index: *//p')
mkdir -p $W/z/IMAGES
avbtool make_vbmeta_image --output $W/z/IMAGES/vbmeta.img --key $K/avb.pem --algorithm SHA256_RSA4096 \
  --rollback_index "$rbi" --flags 0 --padding_size 4096 \
  --include_descriptors_from_image $W/old-vbmeta.img "${fw_args[@]}"
avbtool info_image --image $W/z/IMAGES/vbmeta.img | grep -E '^(Algorithm|Rollback Index|Flags|Public key)'
echo "descriptors: $(avbtool info_image --image $W/old-vbmeta.img | grep -c 'descriptor:') → $(avbtool info_image --image $W/z/IMAGES/vbmeta.img | grep -c 'descriptor:')"
cp "$TF" $W/final-target_files.zip
(cd $W/z && zip -q $W/final-target_files.zip IMAGES/vbmeta.img)
cd $W
else

step "sign target-files (APKs, own APEXes, AVB with our keys; Google's PRESIGNED kept)"
args=()
unzip -p "$TF" META/apexkeys.txt | grep -v PRESIGNED | grep -o '^name="[^"]*"' | sed 's/^name="//; s/"$//' > apex-own.txt
while read -r f; do
  b=${f%.apex}; b=${b%.capex}
  args+=(--extra_apks "$f=$K/$b" --extra_apex_payload_key "$f=$K/$b.pem")
done < apex-own.txt
# Map EVERY non-PRESIGNED APK explicitly (derived from META/apkcerts.txt):
#  - standard keys (build/make/target/product/security/<k>) → our <k>
#    (testkey → releasekey) — -d alone doesn't reach APKs nested inside APEX
#    modules (e.g. NfcNci in com.android.nfcservices)
#  - own source-tree certs (AdServicesApk, FederatedCompute, …) → releasekey,
#    like LineageOS's signing guide lists them one by one
#  - PRESIGNED (Google) stays untouched
unzip -p "$TF" META/apkcerts.txt | grep -v 'certificate="PRESIGNED"' \
  | sed -n 's/^name="\([^"]*\)" certificate="\([^"]*\)".*/\1 \2/p' | sort -u > apk-map.txt
std=0; own=0
while read -r a cert; do
  case "$cert" in
    build/make/target/product/security/*)
      k=$(basename "$cert" .x509.pem); [ "$k" = testkey ] && k=releasekey
      [ -f "$K/$k.pk8" ] || k=releasekey; std=$((std+1)) ;;
    *) k=releasekey; own=$((own+1)) ;;
  esac
  args+=(--extra_apks "$a=$K/$k")
done < apk-map.txt
echo "APK key map: $std standard-key APKs, $own own-cert APKs → releasekey"
# OTA/recovery keys: LineageOS adds its own update key as extra_recovery_keys
# (vendor/lineage/build/target/product/security/lineage); ReplaceOtaKeys needs
# it mapped (else "lineage.x509.pem does not exist") → ours, so recovery and the
# updater accept only OTAs signed by us
# Recovery otacerts = devkey (testkey → releasekey via -d) + extra_recovery_keys. Mapping
# the extra key to $K/releasekey too wrote "k/releasekey.x509.pem" TWICE into
# VENDOR_BOOT's otacerts.zip; recovery's ziparchive rejects duplicate entries
# ("Found duplicate entry … Failed to load keys") → every sideload aborted with
# status 2 (builds 7 + 9, found 2026-11-15 on the first OTA). So map extra recovery
# keys to a same-content copy under its own name: distinct entries, still only our key.
cp "$K/releasekey.x509.pem" "$K/releasekey-recovery.x509.pem"
for k in $(unzip -p "$TF" META/misc_info.txt | sed -n 's/^extra_recovery_keys=//p'); do
  case "$k" in build/make/target/product/security/*) ;; *) args+=(-k "$k=$K/releasekey-recovery"); echo "extra recovery key $k → releasekey (copy)" ;; esac
done
for k in $(unzip -p "$TF" META/otakeys.txt 2>/dev/null | sed 's/\.x509\.pem$//'); do
  case "$k" in build/make/target/product/security/*) ;; *) args+=(-k "$k=$K/releasekey"); echo "OTA key $k → releasekey" ;; esac
done
# every partition the build signs with an AVB key of its own (chained) + vbmeta
for p in $(unzip -p "$TF" META/misc_info.txt | sed -n 's/^avb_\([a-z_]*\)_key_path=.*/\1/p'); do
  args+=(--avb_${p}_key "$K/avb.pem" --avb_${p}_algorithm SHA256_RSA4096)
done
echo "own APEXes: $(wc -l < apex-own.txt), AVB partitions: $(unzip -p "$TF" META/misc_info.txt | grep -c '^avb_[a-z_]*_key_path=')"
# SELinux mac_permissions certs are rewritten via the KEY MAP only (not --extra_apks),
# and -d maps a fixed list without nfc → the nfc test cert stayed (2026-11-14, found
# by the check after 2.5 h). Map every standard key we have explicitly, then pre-check
# that each test cert the tables use has a mapping — before the long signing step.
for k in $(cd "$K" && ls *.x509.pem | sed 's/\.x509\.pem$//'); do
  [ "$k" = testkey ] && continue
  [ -f "$W/otatools/build/make/target/product/security/$k.x509.pem" ] || continue
  args+=(-k "build/make/target/product/security/$k=$K/$k")
done
step "pre-check: every test cert in the SELinux tables has a key mapping"
for name in $(python3 -I /check-mac-certs.py --list "$TF" /in/otatools.zip); do
  n=${name##*/}
  case "$n" in
    testkey) ;;   # -d → releasekey
    *) grep -qx "build/make/target/product/security/$n=$K/$n" <<<"$(printf '%s\n' "${args[@]}")" \
         || { echo "no key mapping for test cert $name (missing $K/$n.x509.pem?)"; exit 1; } ;;
  esac
  echo "  $name → mapped"
done
# LineageOS's device config builds vbmeta with --flags 3 (verification + dm-verity
# OFF, for unlocked phones); sign_target_files_apks keeps avb_vbmeta_args, and a
# LOCKED bootloader refuses such a vbmeta → no bootable OS. avbtool takes the
# last --flags, so append 0. steps/flash.sh check refuses anything but 0.
args+=(--avb_vbmeta_extra_args "--flags 0 ${fw_args[*]}")
# Run from the otatools root: sign_target_files_apks opens the OLD certs by relative
# path (build/make/target/product/security/*.x509.pem, vendor/lineage/...) to rewrite
# */etc/selinux/*_mac_permissions.xml and silently skips any it can't open. From /work
# it found none → tables kept the test certs → SystemUI lost platform_app → RescueParty
# boot loop on every fresh install (2026-11-14).
(cd $W/otatools && sign_target_files_apks -o -d "$K" "${args[@]}" "$TF" $W/signed-target_files.zip)
step "check: every otacerts.zip = only our key, no duplicate entries"
python3 -I /check-otacerts.py $W/signed-target_files.zip "$K/releasekey.x509.pem"
step "check: SELinux mac_permissions carry our certs"
python3 -I /check-mac-certs.py $W/signed-target_files.zip /in/otatools.zip "$K/platform.x509.pem"

if [ -f /in/Magisk.apk ]; then
  step "Magisk into init_boot (chained partition → re-sign only init_boot, vbmeta stays valid)"
  mkdir -p $W/magisk && cd $W/magisk
  unzip -q -o /in/Magisk.apk 'assets/*' 'lib/arm64-v8a/*' lib/x86_64/libmagiskboot.so lib/x86_64/libbusybox.so
  cp -r assets/* .
  # phone-side pieces (go INTO the image) from arm64; host tools from x86_64
  for f in magiskinit magisk init-ld; do cp "lib/arm64-v8a/lib$f.so" "$f"; done
  cp lib/x86_64/libmagiskboot.so magiskboot; cp lib/x86_64/libbusybox.so busybox
  chmod +x magiskinit magisk init-ld magiskboot busybox
  printf '#!/bin/sh\necho\n' > getprop; chmod +x getprop
  unzip -p $W/signed-target_files.zip IMAGES/init_boot.img > init_boot.img
  info=$(avbtool info_image --image init_boot.img)
  size=$(stat -c %s init_boot.img)
  rbi=$(echo "$info" | sed -n 's/^Rollback Index: *//p')
  mapfile -t props < <(echo "$info" | sed -n "s/^ *Prop: \([^ ]*\) -> '\(.*\)'$/\1:\2/p")
  avbtool erase_footer --image init_boot.img
  # keep dm-verity + encryption, never touch vbmeta flags: the phone stays locked
  # PREINITDEVICE: boot_patch.sh only asks the phone (`magisk --preinit-device`) when
  # it runs ON the phone; patched here it was left out -> Magisk app "Requires additional
  # setup ... reinstall within app" (env_check 2), no pre-init storage for module
  # sepolicy rules (2026-11-15). rango: sda10 = metadata (`magisk --preinit-device`
  # works over adb without root).
  KEEPVERITY=true KEEPFORCEENCRYPT=true PATCHVBMETAFLAG=false RECOVERYMODE=false \
    PREINITDEVICE="${MAGISK_PREINIT:-sda10}" \
    PATH=$PWD:$PATH ./busybox sh boot_patch.sh init_boot.img
  pa=(); for p in "${props[@]}"; do pa+=(--prop "$p"); done
  avbtool add_hash_footer --image new-boot.img --partition_name init_boot --partition_size "$size" \
    --key $K/avb.pem --algorithm SHA256_RSA4096 --rollback_index "$rbi" "${pa[@]}"
  mkdir -p z/IMAGES && mv new-boot.img z/IMAGES/init_boot.img
  cp $W/signed-target_files.zip $W/final-target_files.zip
  (cd z && zip -q $W/final-target_files.zip IMAGES/init_boot.img)
  avbtool info_image --image z/IMAGES/init_boot.img | grep -E 'Algorithm|Rollback Index|Public key' | head -4
  cd $W
else
  mv $W/signed-target_files.zip $W/final-target_files.zip
fi
fi   # VBMETA_ONLY
step "check: vbmeta carries the firmware descriptors"
unzip -p $W/final-target_files.zip IMAGES/vbmeta.img > $W/final-vbmeta.img
# info read once + here-string: `avbtool … | grep -q` broke avbtool's pipe at the first
# match and pipefail made that a "not found" (2026-11-14)
vinfo=$(avbtool info_image --image $W/final-vbmeta.img)
for f in $W/fw/*.img; do n=$(basename "$f" .img)
  grep -q "Partition Name: *$n\$" <<<"$vinfo" || { echo "vbmeta lacks $n"; exit 1; }
done
echo "  all $(ls $W/fw | wc -l) firmware partitions present"
python3 -I /check-mac-certs.py $W/final-target_files.zip /in/otatools.zip "$K/platform.x509.pem"

step "OTA package (installable zip, signed with releasekey)"
ota_from_target_files -k $K/releasekey $W/final-target_files.zip /out/lineage-rango-signed-ota.zip
step "fastboot images"
img_from_target_files $W/final-target_files.zip /out/lineage-rango-signed-img.zip
cp $W/final-target_files.zip /out/lineage-rango-signed-target_files.zip
# public half of the AVB key (what `fastboot flash avb_custom_key` takes) — lets
# steps/flash.sh check the images against it without decrypting the keys
cp $K/avb_pkmd.bin /out/avb_pkmd.bin
(cd /out && sha256sum *.zip avb_pkmd.bin > SHA256SUMS)
step "DONE"; ls -la /out
