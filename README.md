# lineage-rango-android-native-nix

> **Unofficial personal build** based on LineageOS. Not affiliated with, endorsed by
> or supported by the LineageOS project or Google. Use at your own risk.

LineageOS 24 (Android 17) for the **Pixel 10 Pro Fold** (`rango`), built on a
throwaway Google Cloud VM and **signed at home** with our own keys — so the
bootloader is **relocked with a key nobody else holds** (verified boot, yellow
state), with Google Play (MindTheGapps) and **native Nix** (a real `/nix/store` for
the Nix-on-Droid app, no proot, no root).

The device-independent native-Nix part is published separately and documented there:
**[android-native-nix](https://github.com/1alecthenice1/android-native-nix)**. This
repository is its worked example: the complete build, signing, relock and update
pipeline for one device.

Status (2026-11-16): build 11 on the phone, bootloader locked with our key. Native Nix
test suite all passing (glibc programs, `home-manager switch`, local builds, Python
multiprocessing, interactive bash). Updates install via the Updater app (local
update) **and** recovery sideload, both accepting only our key. No root (Magisk is
optional at signing time, off since build 10).

## How it works

```
 build host (aarch64 NixOS)                     Google Cloud (spot VM)
 ─────────────────────────                     ──────────────────────
 steps/vm-create.sh  ───────────────────────▶  NixOS image (vm/builder.nix)
                                               └─ podman: Ubuntu 24.04 container
 steps/build.sh      ───────────────────────▶     repo sync, extract blobs from
                                                  Google's factory image, build
 steps/fetch.sh      ◀─── target-files + otatools
 steps/vm-delete.sh  ───────────────────────▶  (everything deleted)
 steps/keys-create.sh   (once; keys never leave home unencrypted)
 steps/sign.sh          x86-64 container under QEMU: sign APKs/APEXes/AVB,
                        (optional: Magisk into init_boot), OTA zip + fastboot images
 steps/update.sh        OTA onto the locked phone: Updater app or recovery sideload
```

- **Build host:** NixOS on a `c2d-highcpu-56` spot VM (56 vCPU, 110 GB RAM),
  4×375 GB local NVMe as RAID 0 for `/src`. Booted from our own GCE image
  (`steps/image-build.sh`) — nixos-anywhere's kexec resets C2D VMs.
- **Build environment:** a pinned Ubuntu 24.04 container with LineageOS's
  documented package list, packages from a dated `snapshot.ubuntu.com` snapshot.
  We tried a NixOS FHS environment first; it hit one missing host piece per run
  (Python modules, `/usr/include`, `crtbeginS.o`/libgcc for the kernel build).
  Matching the environment Google and LineageOS test against was less work.
- **Signing:** on the aarch64 board, Android's x86-64 `otatools` run in an
  x86-64 container under QEMU user emulation. Google's prebuilt APEX/APKs
  (`PRESIGNED`) keep Google's signatures; everything else gets ours.
- **Optional root under a locked bootloader** (`MAGISK=1`, off since build 10):
  `init_boot` is a chained AVB partition on Tensor, so Magisk patches it and only
  `init_boot` is re-signed with our AVB key; `vbmeta` stays valid.

## Additions to LineageOS

| | |
|---|---|
| MindTheGapps (`cinnamonbun`) built in | `extras/extras.mk`, without the Google app (`patches/vendor/gapps`) |
| Fingerprint enrollment fix | `patches/packages/apps/Settings` (GrapheneOS's fix + a fallback) — see below |
| Restrict USB while locked by default | `patches/lineage-sdk` |
| Own boot animation + wallpaper | `extras/` |
| Native `/nix` for one app (Nix without proot): zygote bind + seccomp + `/usr/bin` + `/dev/shm`, `nix_app` SELinux domain pinned to Nix-on-Droid's F-Droid key, phantom process killer off | `patches/{bionic,frameworks/base,system/sepolicy}`, `extras/`, [android-native-nix](https://github.com/1alecthenice1/android-native-nix), [docs/nix-design.md](docs/nix-design.md) |
| Quick Share extension keeps Google's signature (build 12+) | `patches/device/google/rango` — see below |
| Art feed instead of Google's news on the page left of the home screen (build 12+): public-domain works from The Met + Cleveland Museum of Art, all departments in shuffled rotation | `extras/ArtFeed`, `patches/packages/apps/Launcher3`; dev build + phone install: `steps/artfeed-dev.sh` |
| `user` build variant | not `userdebug` like official builds |

## Findings worth knowing (Android 17 / LineageOS 24 / rango)

- **Factory image must match the device tree.** The tree's `lineage_rango.mk`
  names the Google build it was made for (here `CP3A.261005.005`); extracting from a
  newer factory image misses versioned APKs and produces no `rango-vendor.mk`.
- **The kernel is built from source with Kleaf** during the build (~20 min,
  `out-kernel/`, ~22 GB); Bazel's sandbox needs host C headers and libgcc.
- **`otatools.zip` stays in Soong's intermediates** on Android 17
  (`out/soong/.intermediates/build/make/tools/otatools_package/…/gen/otatools.zip`),
  not in `$OUT`.
- **Git LFS:** `repo sync` leaves pointer files for e.g. the prebuilt WebView APK
  (`failed opening zip: Invalid file`) → `git lfs pull` after syncing.
- **podman's default pids limit (2048)** breaks a 56-job build
  (`unable to create native thread`) → `--pids-limit=-1`.
- **googlesource rate-limits** 32 parallel fetches (`RESOURCE_EXHAUSTED`) → 8 jobs + retries.
- **`build/envsetup.sh` clobbers `$f`** in the calling shell.
- **APKs inside APEX modules** carry their own source-tree certificates; map them
  (derived from `META/apkcerts.txt`) or `sign_target_files_apks` fails.
- **GCE:** `c2d-highcpu-56` takes only 0, 4 or 8 local SSDs; new projects start
  at 32 vCPU (64 was approved instantly).
- **Fingerprint (Goodix side sensor):** the HAL pauses enrollment after three
  rejected touches and reports vendor acquired code 1000; stock Pixel software
  resumes it via the HAL's binder extension
  `com.google.hardware.biometrics.sidefps.IFingerprintExt` (`resumeEnroll()`,
  transaction 2). Nothing in AOSP/LineageOS makes that call, so enrollment hangs
  (LineageOS issue #8005 on the original Pixel Fold). Builds 7–10 made the call
  from frameworks/base (auto-resume). Since build 11: **GrapheneOS's fix** (Dmitry
  Muhomor, 2024, `30dae1da04`, cherry-picked unchanged): Settings' AOSP hook
  `SfpsEnrollmentFeature` shows a "try a different part" dialog and resumes on OK
  — like stock Pixels, with a proper `IFingerprintExt.aidl` — plus our fallback to
  the framework's vendor strings (LineageOS overlays them for the framework only;
  Settings' empty array would have thrown at the pause).

- **LineageOS builds `vbmeta` with `--flags 3`** (verification and dm-verity off,
  meant for unlocked phones), and `sign_target_files_apks` keeps those args. A
  bootloader relocked onto that refuses to boot. Signing appends `--flags 0`
  (avbtool takes the last one); `steps/flash.sh check` refuses anything else.
- **LineageOS's own update key** is listed as `extra_recovery_keys`;
  `ReplaceOtaKeys` needs it mapped (`-k …/lineage=<our releasekey>`).
- **otatools `chmod` key files** while zipping the OTA certs → a read-only key
  mount fails; we copy keys into a RAM-only tmpfs inside the container.
- **Native `/nix` and Android's SELinux** (checked against lineage-24.0
  `system/sepolicy`): only app domains may execute files on `/data`, only zygote
  may start app domains, and apps may not create hard links. So a root daemon
  can't run store code for an app; zygote binding the app's own data dir onto a
  `/nix` mountpoint in that app's mount namespace needs one new type and one
  `mounton` rule, and no neverallow change. rango's GKI kernel has no user
  namespaces (no NNS-style launcher, no Nix sandbox).
- **Quick Share extension (`MoseyApp`, `com.google.android.mosey`)** is listed in
  rango's `proprietary-files.txt` without `;PRESIGNED`, so every LineageOS build
  re-signs it with the platform key. Play services' Nearby Share API then refuses
  it ("SecurityException: Denied access to unsuspend method") and it crash-loops
  every ~12 s (2,645 crashes in 2 days on build 11) — Quick Share drops at random.
  Build 11 workaround on the phone: `adb shell pm disable-user --user 0
  com.google.android.mosey` (re-enable with `pm enable` after build 12).
  `steps/check-build.sh` checks the PRESIGNED entry.
- **Root image extras** need `PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST`.

## Cost

A full build is a few dollars of spot VM time; nothing runs between builds
(`steps/vm-delete.sh`). A GCP budget alert guards the project.

## Never in this repository

Signing keys, Google's proprietary files (extracted at build time from Google's
factory image), and build outputs.

## References

- [robotnix](https://github.com/nix-community/robotnix) — Nix-native Android builds
- [mio-aotearoa/repo](https://github.com/mio-aotearoa/repo) — robotnix fork with LineageOS 24, Termux `/nix`
- [reo101/NNS](https://github.com/reo101/NNS) — native `/nix` on Android (ideas; no licence, no code used)
- [GrapheneOS Settings](https://github.com/GrapheneOS/platform_packages_apps_Settings) — fingerprint enrollment fix (cherry-picked)
- LineageOS wiki: build and signing guides

## Licence

Apache-2.0 for our scripts and patches (they modify Apache-licensed AOSP/LineageOS
code). `tools/avbtool.py` is Google's, MIT (see its header).
