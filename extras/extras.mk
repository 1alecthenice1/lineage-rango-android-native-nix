# Our additions on top of LineageOS for rango. remote-build.sh copies this
# directory to vendor/extras and inherits it from device/google/rango/lineage_rango.mk.

# Google apps + Play services built into the signed system (MindTheGapps,
# branch cinnamonbun = Android 17, synced to vendor/gapps via local manifest)
$(call inherit-product, vendor/gapps/arm64/arm64-vendor.mk)

# Boot animation: the boot logo's flow lines (generative-art Flow seed 23,
# ~/art/boot-logo BootAnim.hs + pack-bootanim.sh); read by vendor/lineage's
# BoardConfigSoong.mk instead of generating LineageOS's own
TARGET_BOOTANIMATION := vendor/extras/media/bootanimation.zip

# Default wallpaper: NOT an overlay here — LineageOS's own fills every density
# bucket and is inherited before this file, so ours never won (build 3,
# 2026-11-14). vm/remote-build.sh copies extras/wallpaper/default_wallpaper.png
# (2560x2560 square: the Fold crops it for the outer 1080x2364 and the near-square
# inner 2152x2076 screen) over LineageOS's files in the source tree instead.

# Native /nix for one app (docs/nix-design.md, option Z): empty mountpoint in the
# verified root image; zygote (patches/frameworks/base/0002) binds the app's data
# dir onto it in that app's mount namespace. Empty property = feature off.
PRODUCT_COPY_FILES += vendor/extras/nix/README:$(TARGET_COPY_OUT_ROOT)/nix/README
# the system image's artifact path requirement (generic_system.mk) allows only
# listed extra files, like LineageOS does for its own
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += root/nix/README
# /usr/bin mountpoint: zygote binds /system/bin there for the Nix app (patch 0006)
PRODUCT_COPY_FILES += vendor/extras/usr-bin/README:$(TARGET_COPY_OUT_ROOT)/usr/bin/README
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += root/usr/bin/README
PRODUCT_SYSTEM_EXT_PROPERTIES += ro.nix.package=com.termux.nix
# Phantom process killer off by default (= developer option "Disable child process
# restrictions"): Android 12+ kills app child processes above 32 — on build 9 it
# killed 40 test processes and the Nix session's bash at once; the Settings.Global
# switch stopped it (2026-11-15). FeatureFlagUtils reads this prop when the global
# setting is unset; a user/adb setting still overrides it.
PRODUCT_SYSTEM_EXT_PROPERTIES += persist.sys.fflag.override.settings_enable_monitor_phantom_procs=false
# /etc/resolv.conf for native Nix (musl/glibc read only this file; Android's own
# resolver uses netd and ignores it). Quad9 + Cloudflare.
PRODUCT_COPY_FILES += vendor/extras/nix/resolv.conf:$(TARGET_COPY_OUT_SYSTEM)/etc/resolv.conf
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += system/etc/resolv.conf
# /dev/shm mountpoint (init), private tmpfs per Nix-app process (zygote patch 0007)
PRODUCT_COPY_FILES += vendor/extras/nix/nix.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/nix.rc
PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += system/etc/init/nix.rc
SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += vendor/extras/sepolicy/private

# Updates: no official channel (our recovery only accepts OTAs signed with our
# key, so offering LineageOS's builds would just fail after a 1.7 GB download).
# Updates come from steps/update.sh (Updater local update or recovery
# sideload). .invalid never resolves; point it at your own update server if you
# run one.
PRODUCT_SYSTEM_EXT_PROPERTIES += lineage.updater.uri=https://updates.invalid/{device}.json
