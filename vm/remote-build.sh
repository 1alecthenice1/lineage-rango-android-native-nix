#!/usr/bin/env bash
# Runs ON the build VM (inside aosp-env, started by steps/build.sh in tmux).
# Unsigned LineageOS for rango: target-files + otatools; signing happens on the build host.
set -euo pipefail
BRANCH=${BRANCH:-lineage-24.0}
VARIANT=${VARIANT:-user}
# must match the Google build the device tree targets (device/google/rango/
# lineage_rango.mk BuildDesc; the tree moves to a new one each security bulletin)
FACTORY_URL=${FACTORY_URL:-https://dl.google.com/dl/android/aosp/rango-cp3a.261005.005-factory-7110a4ac.zip}
FACTORY_SHA=${FACTORY_SHA:-7110a4ac2f939e028f102bd0f034552e19dc3c90a3bb5b9dcdaaede5ae049eb5}
JOBS=$(nproc)
# SYNC=0: reuse the tree from the previous run on this VM (no repo sync, same
# revisions, no new extraction) — only our patches + extras are reapplied, so the
# build is incremental (e.g. build 3 = build 2 + /nix)
SYNC=${SYNC:-1}
step() { printf '\n=== %s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
mkdir -p /src/lineage /src/factory
# no ccache: the data disk is deleted after every build, so the cache would never
# be reused (reruns in the same session are incremental anyway)
export USE_CCACHE=0

step "factory image (vendor blobs + firmware)"
# not "$f": build/envsetup.sh reuses that name in its own loops and wipes it
FACTORY_ZIP=/src/factory/$(basename "$FACTORY_URL")
[ -s "$FACTORY_ZIP" ] || curl -fsSL --retry 5 -C - -o "$FACTORY_ZIP" "$FACTORY_URL"
echo "$FACTORY_SHA  $FACTORY_ZIP" | sha256sum -c -

cd /src/lineage
git config --global user.name builder; git config --global user.email builder@localhost
git config --global color.ui false
if [ "$SYNC" = 1 ]; then
step "repo init $BRANCH"
[ -d .repo ] || repo init -u https://github.com/LineageOS/android.git -b "$BRANCH" --git-lfs --depth=1 --no-clone-bundle
step "local manifest: MindTheGapps (Android 17 = cinnamonbun)"
mkdir -p .repo/local_manifests
cat > .repo/local_manifests/extras.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="mtg" fetch="https://gitlab.com/MindTheGapps/" />
  <project name="vendor_gapps" path="vendor/gapps" remote="mtg" revision="cinnamonbun" clone-depth="1" />
</manifest>
XML
step "repo sync"
# reruns: drop our previously applied patches first (sync would try to rebase them)
[ -d .repo/projects ] && repo forall -c 'git am --abort 2>/dev/null; git checkout -q --detach 2>/dev/null; git reset -q --hard m/'"$BRANCH"' 2>/dev/null' >/dev/null 2>&1 || true
# android.googlesource.com answers RESOURCE_EXHAUSTED to 32 parallel fetches from
# one IP: 8 jobs, per-fetch retries, and whole-sync retries with a pause
SYNC_JOBS=${SYNC_JOBS:-8}
for try in 1 2 3 4 5 6; do
  repo sync -c -j"$SYNC_JOBS" --no-tags --no-clone-bundle --optimized-fetch --prune --retry-fetches=5 && break
  [ "$try" = 6 ] && { echo "repo sync failed 6 times"; exit 1; }
  echo "repo sync attempt $try failed, retrying in 5 min"; sleep 300
done
step "Git LFS files (prebuilt APKs such as the WebView; repo sync left pointers)"
git lfs install --skip-repo >/dev/null
repo forall -c 'git lfs ls-files 2>/dev/null | grep -q . && { git lfs pull || echo "LFS pull incomplete in $REPO_PATH (ok if only test data)"; }' || true
else
  [ -d .repo/projects ] && [ -f /src/manifest-pinned.xml ] || { echo "SYNC=0 needs a previous full run on this VM"; exit 1; }
  step "SYNC=0: keep the tree, drop our previous patch commits"
  repo forall -c 'git am --abort 2>/dev/null; git checkout -q --detach 2>/dev/null; git reset -q --hard m/'"$BRANCH"' 2>/dev/null' >/dev/null 2>&1 || true
fi
set +u; source build/envsetup.sh
step "breakfast rango $VARIANT (pulls device repos)"
breakfast rango "$VARIANT" || true   # fails until vendor/google/rango exists
set -u
# pin BEFORE patching: afterwards HEADs are our local patch commits, which
# exist nowhere upstream
if [ "$SYNC" = 1 ]; then
  step "pin the exact source revisions"
  repo manifest -r -o /src/manifest-pinned.xml
fi
step "our patches + extras (after the first breakfast: device repos exist now)"
( cd /src/patches && find . -name '*.patch' | sort ) | while read -r p; do
  proj=$(dirname "${p#./}")
  echo "  $proj: $(basename "$p")"
  git -C "$proj" -c user.name=builder -c user.email=builder@localhost am -q --3way "/src/patches/$p"
done
rm -rf vendor/extras && cp -r /src/extras vendor/extras
# default wallpaper: overwrite every framework-res default_wallpaper.png (all density
# / sw600dp / sw720dp buckets; not the 32x32 television one) — an overlay of ours
# loses to LineageOS's. The next run's `git reset --hard` restores the originals.
n=0
while read -r f; do cp vendor/extras/wallpaper/default_wallpaper.png "$f"; echo "  wallpaper → $f"; n=$((n+1))
done < <(find vendor/lineage device/google -path '*/frameworks/base/core/res/res/drawable*/default_wallpaper.png' \
           ! -path '*television*' 2>/dev/null)
[ "$n" -gt 0 ] || { echo "no default_wallpaper.png found to replace"; exit 1; }
# recovery + fastbootd theme: Everforest colours + our emblem in every density's images
# (menu colours: patches/bootable/recovery). Reset by the next run's git reset --hard.
mapfile -t rdirs < <(ls -d bootable/recovery/res-*/images)
[ "${#rdirs[@]}" -gt 0 ] && [ -f "${rdirs[0]}/fastbootd.png" ] || { echo "recovery images not where expected"; exit 1; }
bash vendor/extras/recovery/recovery-theme.sh vendor/extras/recovery/emblem.png "${rdirs[@]}"
rlogo_hashes=$(for d in "${rdirs[@]}"; do identify -format '%#\n' "$d"/logo_image.png "$d"/logo_image_switch.png "$d"/fastbootd.png; done)
set +u
step "extract proprietary files from the factory image"
# fresh every time: extract-utils "restores" pinned files from an existing
# vendor dir, which kept files from an earlier attempt with another factory build
if [ "$SYNC" = 1 ] || [ ! -d vendor/google/rango ]; then
  rm -rf vendor/google/rango
  ( cd device/google/rango && ./extract-files.py "$FACTORY_ZIP" )
fi
grep -q vendor/extras/extras.mk device/google/rango/lineage_rango.mk ||
  echo '$(call inherit-product, vendor/extras/extras.mk)' >> device/google/rango/lineage_rango.mk
breakfast rango "$VARIANT"
set -u
# boot animation on BOTH Fold screens: multi-display is a fixed read-only aconfig flag
# (com.android.graphics.bootanimation.flags.multidisplay), off in LineageOS's release
# config → only the first (inner) display got it (2026-11-14). Add a value for the
# active release (git reset --hard doesn't remove this untracked dir; rewritten each run).
rel=$(sed -n 's/.*--release \([a-z0-9_]*\).*/\1/p' out/soong/release-config/args-lineage_rango.txt 2>/dev/null)
rel=${rel:-$(get_build_var TARGET_RELEASE)}
fd=build/release/aconfig/$rel/com.android.graphics.bootanimation.flags
[ -f build/release/aconfig/$rel/Android.bp ] || { echo "no aconfig value set for release '$rel'"; exit 1; }
mkdir -p "$fd"
cat > "$fd/Android.bp" <<BP
aconfig_values {
    name: "aconfig-values-platform_build_release-$rel-com.android.graphics.bootanimation.flags-all",
    package: "com.android.graphics.bootanimation.flags",
    srcs: ["*_flag_values.textproto"],
}
BP
cat > "$fd/multidisplay_flag_values.textproto" <<'TP'
flag_value {
  package: "com.android.graphics.bootanimation.flags"
  name: "multidisplay"
  state: ENABLED
  permission: READ_ONLY
}
TP
echo "  aconfig: bootanimation multidisplay ENABLED for release $rel"
# vendor/lineage/bootanimation's genrule copies TARGET_BOOTANIMATION with a bare `cp`
# without declaring it as an input, so incremental builds keep the old zip (build 4,
# 2026-11-14) — drop the cached copies so it's always copied fresh
rm -rf out/soong/.intermediates/vendor/lineage/bootanimation "$OUT"/product/media/bootanimation.zip
step "build target-files + otatools ($JOBS jobs)"
m target-files-package otatools-package
out=$OUT
ls -la "$out"/obj/PACKAGING/target_files_intermediates/*-target_files*.zip
# the wallpaper the phone picks (xxxhdpi / sw720dp buckets) must be ours: compare
# pixel hashes (identify %#), aapt2 may re-encode the PNG
tf=$(ls "$out"/obj/PACKAGING/target_files_intermediates/*-target_files*.zip | head -1)
rro=$(unzip -Z1 "$tf" | grep -E 'overlay/framework-res__.*auto_generated_rro_product\.apk$' | head -1)
unzip -p "$tf" "$rro" > /tmp/fw-rro.apk
for b in drawable-xxxhdpi-v4 drawable-sw720dp-nodpi-v13; do
  [ "$(unzip -p /tmp/fw-rro.apk "res/$b/default_wallpaper.png" | identify -format '%#' -)" = "$(identify -format '%#' vendor/extras/wallpaper/default_wallpaper.png)" ] \
    || { echo "wallpaper in $b is not ours"; exit 1; }
done
echo "  wallpaper check OK (xxxhdpi + sw720dp = ours)"
for f in logo_image.png logo_image_switch.png fastbootd.png; do
  h=$(unzip -p "$tf" "VENDOR_BOOT/RAMDISK/res/images/$f" | identify -format '%#' -)
  grep -qx "$h" <<<"$rlogo_hashes" || { echo "recovery $f is not ours"; exit 1; }
done
echo "  recovery theme check OK"
[ "$(unzip -p "$tf" PRODUCT/media/bootanimation.zip | sha256sum | cut -d' ' -f1)" = \
  "$(sha256sum vendor/extras/media/bootanimation.zip | cut -d' ' -f1)" ] || { echo "boot animation is not ours"; exit 1; }
echo "  boot animation check OK"
# fixed read-only flags are compiled in (not in aconfig_flags.pb): check the module's cache
out/host/linux-x86/bin/aconfig dump-cache --format='{fully_qualified_name}={state}' \
    --cache out/soong/.intermediates/frameworks/base/cmds/bootanimation/bootanimation_flags/aconfig-cache.pb \
  | grep -qx 'com.android.graphics.bootanimation.flags.multidisplay=ENABLED' \
  || { echo "bootanimation multidisplay flag is not ENABLED in the build"; exit 1; }
echo "  multidisplay flag check OK"
# Android 17: otatools.zip stays in soong's intermediates (no copy in $OUT)
find out/soong/.intermediates/build/make/tools/otatools_package "$out" -name otatools.zip -printf '%p %s\n' | grep . 
step "DONE"
