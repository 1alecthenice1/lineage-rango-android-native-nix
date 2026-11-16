# Native `/nix` on rango — design (draft 2026-11-13, for build 3; option Z)

Goal: a real `/nix/store` on the phone, so Nix-on-Droid runs **without proot**
(native speed, real paths, binary cache hits for aarch64-linux), while the phone
stays a **locked, verified-boot** Android: nothing in `/nix` can gain root, and no
app other than the one(s) we allow can see or change the store.

## Requirements (agreed earlier)

1. Namespace setup only by a native launcher: `unshare` + tmpfs root + recursive
   mount moves; never `pivot_root` in the global namespace. The rest of Android
   never sees `/nix`.
2. SELinux: never `system_data_file` for the store (AOSP neverallow on app
   execute); own types where new objects appear (`/nix` mountpoint). Revised
   2026-11-13: the store itself keeps `app_data_file` — rule 4 below allows nothing
   else for files an untrusted app creates. **No
   neverallow may be disabled** (no `if false` on Soong's checks, unlike
   android_patches).
3. No app gains root through Nix: single-user Nix owned by the app's UID, or a
   nix-daemon only with separate build users + sandbox. Start with single-user.
4. Locked bootloader, `user` build, `ro.debuggable=0` stay as they are.

## Facts that shape the design

- The root image is read-only and verified (dm-verity) → the mountpoint must exist
  **at build time**: `PRODUCT_COPY_FILES += …/nix/README:$(TARGET_COPY_OUT_ROOT)/nix/README`
  (android_vendor_pfa's trick; build 1 has the `ROOT/` tree).
- Apps have no capabilities and (on rango) no user namespaces, so an app can't
  set up a mount namespace itself; zygote does it for every app anyway.
- Nix-on-Droid targets SDK 28 → domain `untrusted_app_27`, which may still execute
  files in its own app data (that is how proot works today).

## What the platform allows (checked 2026-11-13)

On the phone (LineageOS 24, kernel 6.6.127-android15-8): **`CONFIG_USER_NS` is not
set**; Nix-on-Droid runs as `untrusted_app_27`, UID 10271, CapEff 0, Seccomp 2,
`NoNewPrivs: 0`. OVERLAY_FS and FUSE_FS are built in.

In our tree's `system/sepolicy` (lineage-24.0 `d61fd80`), neverallows that decide it:

1. `neverallow { domain -appdomain … } { data_file_type -apex_art_data_file
   -dalvikcache_data_file -system_data_file -apk_data_file }:file no_x_file_perms`
   → **only app domains may execute anything stored on /data.**
2. `neverallow { domain -simpleperf_app_runner -runas -app_zygote
   -native_app_zygote -webview_zygote -zygote } { appdomain … }:process
   { transition dyntransition }` → **only zygote (and run-as/simpleperf) may start a
   process in an app domain.**
3. `neverallow { domain -apexd -dexopt_chroot_setup … -init -kernel -recovery
   -update_engine -vold -zygote } { fs_type -sdcard_type -fusefs_type }:filesystem
   { mount … }` → new filesystems (tmpfs root) only by init/vold/zygote/….
4. `neverallow { all_untrusted_apps -mediaprovider } { fs_type … file_type
   -app_data_file … }:dir_file_class_set { create unlink }` → an untrusted app can
   only create files labelled `app_data_file` (so the store must carry that label).
5. `neverallow zygote app_data_file_type:dir ~getattr` → zygote may bind an app's
   data dir as a whole, but never look inside it.

## Options

- **A. NNS-style launcher in the app** (user + mount namespace): impossible — no
  `CONFIG_USER_NS`, and an app can't get CAP_SYS_ADMIN otherwise.
- **B. Root service `nixd` that spawns sessions in a namespace:** impossible
  without breaking rules 1 + 2 (a non-app domain can neither run store code nor
  hand a process to an app domain). Dropped.
- **Z. Zygote binds the allowed app's data dir onto `/nix` in that app's own mount
  namespace (chosen).** Zygote already unshares a mount namespace per app and
  bind-mounts each app's data dir from `/data_mirror` (`isolateAppData`,
  `createAndMountAppData` in `com_android_internal_os_Zygote.cpp`). One more
  `BindMount("/data/data/<pkg>", "/nix")` there, only when the process belongs to
  the package named in the ROM (`ro.nix.package`, e.g. `com.termux.nix`):
  - no daemon, no root process, no new domain; the app runs Nix single-user as
    itself (`untrusted_app_27` may execute its own `app_data_file`s);
  - store files stay `app_data_file` with the app's MLS categories (rule 4 ✓),
    encrypted with the user's credentials like any app data, removed with the app;
  - zygote binds the package dir as a whole (rule 5 ✓); `/nix` = the app's data
    dir, so the store lives at `<appdir>/store`, `<appdir>/var`;
  - every other app sees only the empty mountpoint (requirement 1 ✓);
  - policy: `type nix_mnt_file, file_type;` for the `/nix` mountpoint +
    `allow zygote nix_mnt_file:dir mounton;` — no neverallow touched.
- **S. Symlink `/nix → /data/data/<pkg>/files/nix` in the root image** (fallback):
  no code at all, but every app sees the link, and Nix refuses a symlinked store
  unless `NIX_IGNORE_SYMLINK_STORE=1`; `readlink -f` gives non-store paths.
- **C. mio-aotearoa: init bind-mounts globally** — `/nix` in every namespace
  (requirement 1 ✗). Not used.

## Pieces for build 3 (option Z)

| Piece | Where | Notes |
|---|---|---|
| `/nix` mountpoint | `extras/nix/README` + `PRODUCT_COPY_FILES` to `$(TARGET_COPY_OUT_ROOT)` | empty dir in the verified root |
| allowed package | `PRODUCT_SYSTEM_EXT_PROPERTIES += ro.nix.package=com.termux.nix` | read-only, set at build time; empty = feature off |
| zygote | `patches/frameworks/base/000x-zygote-nix-bind.patch` (~30 lines) | after `isolateAppData`, before dropping caps: if `ro.nix.package` matches the process's package and uid is a regular app uid (not isolated/sdk sandbox) → bind `/data/data/<pkg>` on `/nix`, `MS_NOSUID|MS_NODEV` kept from the source |
| SELinux | `extras/sepolicy/` via `SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS` | `nix_mnt_file` + `file_contexts` `/nix(/.*)? u:object_r:nix_mnt_file:s0` + zygote `mounton`; maybe `dontaudit appdomain nix_mnt_file:dir getattr` for other apps |
| Nix-on-Droid | its login without proot: exec the profile's shell directly, `NIX_STATE_DIR`/`nix.conf` with `sandbox = false`, `build-users-group =` | store moves once: `files/nix/{store,var}` → `<appdir>/{store,var}` (same filesystem, `mv`), `files/nix` → symlink `..` so the proot login keeps working during the switch |

Store paths stay `/nix/store/…` — the same as NoD's inside proot — so the flake in
the session flake (android-native-nix `session/`) works unchanged.

## Session side: Nix-on-Droid's app as terminal, no Nix-on-Droid modules (researched 2026-11-13)

Nix-on-Droid (`nix-community/nix-on-droid` 3264519) is built around proot, not just
its login: `build.installationDir = /data/data/com.termux.nix/files/usr`; the login
runs `proot-static -b usr/nix:/nix -b usr/bin:/bin! -b usr/etc:/etc! -b usr/usr:/usr
-b usr/tmp:/tmp -b /:/android --link2symlink --sysvipc`, and its activation writes
`/bin/login`, `/etc/…`, `/usr/lib/login-inner` — paths that only exist inside proot.
So natively we keep only the **app** (terminal + `$PREFIX/bin/login` hook) and
replace the rest:

- **Store:** fresh, at `/nix/store` = `<appdir>/store` (zygote's bind of
  `/data/data/com.termux.nix`). Not a copy of the proot store: that one lives in
  `files/usr/nix` and may contain `--link2symlink` artefacts (fake hard links
  pointing into `files/usr/.l2s`).
- **Bootstrap:** a static `nix` binary (single file, no store dependencies) in
  `files/`, then `nix profile install` / home-manager into the native store.
- **Config:** the `phone/` flake gets a standalone **home-manager** configuration
  (packages + ssh config + known_hosts are all home-manager-able); the
  nix-on-droid output stays for the proot fallback.
- **Login:** `files/usr/bin/login` (what the app executes) becomes a small
  `/system/bin/sh` script: if `/nix/store` exists → set `HOME`, `PATH`
  (~/.nix-profile/bin + /system/bin), `NIX_SSL_CERT_FILE`, `TMPDIR`
  (`<appdir>/cache`), exec the profile's shell; else → old proot login (fallback).
- **nix.conf:** `sandbox = false` (no user namespaces), `build-users-group =`,
  `auto-optimise-store = false`.
- **Hard links: apps may not create them.** Compiled policy of build 3
  (`plat_sepolicy.cil`): app domains get `create unlink rename …` on
  `app_data_file`, **no `link`** (hence proot's `--link2symlink`). **Correction
  (2026-11-15): a neverallow forbids it** — `neverallow untrusted_app_all
  file_type:file link` (expanded per untrusted_app_NN in the compiled policy); the
  denial isn't even logged. Allowing it needs a system/sepolicy change (own nix_app
  domain + an exception in that neverallow, build 11 plan). Until then: substitution from the binary
  cache (NARs have no hard links) and normal use work; local builds that create
  hard links would fail — build those on the build host.

## Open points

1. `#!/usr/bin/env` shebangs in user scripts: no `/usr` natively. Nix-built
   programs use store shebangs; for own scripts use `nix-shell`/store paths, or a
   `/usr/bin/env` mountpoint later the same way as `/nix`.
2. Nix builds on the phone run without a sandbox (no user namespaces) — same as
   today under proot; substitutes from cache.nixos.org cover nearly everything.
3. Child processes the app forks keep the namespace (same process tree); a second
   process started by zygote for the same package (`:service`) gets the bind too.
4. Multi-user: user 0 only (path `/data/user/<userId>/<pkg>` otherwise).
5. Licences: NNS has no licence → ideas only, our own code.

## Later (not build 3)

- a VPN/mesh daemon from the store as an init service in its own domain.
- nix-daemon with build users (multi-app store) — only if more than one app needs
  `/nix`.

## Seccomp: glibc programs are killed natively (found 2026-11-15, build 7)

The static (musl) `nix` runs natively, but every nixpkgs (glibc) program dies at
startup: strace in the app's Failsafe shell shows
`set_robust_list(...) → SIGSYS {si_code=SYS_SECCOMP, si_syscall=__NR_set_robust_list}`.
Android's app seccomp filter (bionic `SYSCALLS.TXT` + `SECCOMP_ALLOWLIST_*`, default
action SECCOMP_RET_TRAP) has no entry for it. glibc 2.42 (aarch64, objdump of
libc/ld.so/libm/libresolv vs. bionic main's lists) uses these calls that apps may not make:
- `set_robust_list`, `rseq`: every program at startup (inside ld.so, before any
  LD_PRELOAD; `GLIBC_TUNABLES=glibc.pthread.rseq=0` would only cover rseq)
- `faccessat2`: `faccessat()` tries it first (bash `[ -x ]` via eaccess)
- `fchmodat2`: `fchmodat()` with AT_SYMLINK_NOFOLLOW
- not needed (deliberately blocked or absent hardware/kernel features): SysV IPC,
  mq_*, new mount API, fanotify, pkey_*, map_shadow_stack, process_mrelease, obsolete calls.
An app can only tighten its own filter, so the fix has to be in the ROM: allow those
four for the Nix app (`ro.nix.package`), in the same zygote path that binds `/nix`.
Also needed natively: `/etc/resolv.conf` (none on Android; musl/glibc don't use netd)
— a Magisk module at first; /etc/resolv.conf ships in the image since build 8.
**Fix (2026-11-15, next build):** `patches/bionic/0001-seccomp-nix-app-filter.patch` adds
`set_app_nix_seccomp_filter()` (app filter + those four, as a separate block in front so
the 64→32-bit jump keeps its length); `patches/frameworks/base/0005-zygote-nix-app-seccomp.patch`
uses it for the process MountNixStore bound /nix in. Tested on the build host (aarch64) by compiling
the patched seccomp_policy.cpp against stand-in generated headers: stock app filter →
SIGSYS for all four, nix filter → allowed, ordinary calls unaffected.
**Also for build 8:** `openat2` in the same list (Go 1.24 `os.Root`, newer Rust/systemd —
only an ENOSYS fallback, SIGSYS kills); `/usr/bin` = `/system/bin` for the Nix app
(empty `/usr/bin` mountpoint in the root image, labelled `nix_mnt_file`; `/usr` =
`system_file`; zygote patch 0006) so `#!/usr/bin/env …` works; `sign.sh` refuses a
target-files without ROOT/nix/README, ROOT/usr/bin/README, SYSTEM/etc/resolv.conf.
Not added on purpose: io_uring (blocked for apps after many CVEs; libuv ≥1.48 has it
off by default), SysV IPC, landlock, futex2, NUMA calls.
**`/dev/shm` (build 9, 2026-11-15):** Android has none, so glibc `shm_open`/`sem_open`
fail natively (an error, not SIGSYS: Python multiprocessing, some databases/browsers).
init creates an empty `/dev/shm` (`extras/nix/nix.rc`, type `nix_shm_mnt`, a dev_type);
for the Nix app zygote mounts a 1 GB tmpfs there (nosuid/nodev/noexec, 0700, app-owned)
with `context=` the app data dir's label read via getfilecon (app_data_file + the app's
MLS categories) — the only label untrusted apps may create files with (app_neverallows).
Zygote may mount/relabel filesystems (exempt in domain.te); the relabel neverallows cover
fs_type and file classes, not `app_data_file:filesystem`. Failure is logged, not fatal.
Check on the phone: `ls -ldZ /dev/shm` in the native shell, `python3 -c 'import
multiprocessing as m; m.Lock()'`.
**`/tmp` dropped (build 9 policy check, 2026-11-15):** zygote may only `getattr`
`app_data_file_type` dirs (zygote.te:314) and never search `shell_data_file` (shell.te:669),
so it can't mount over Android's `/tmp`; tools get env vars instead (TMUX_TMPDIR, ssh-agent
-a, TMPDIR). Originally planned: **`/tmp`** gets a second private tmpfs (Android's `/tmp` is adb shell's,
`shell_data_file`, 0771 — the app can't write; tmux, ssh-agent and scripts hardcode
/tmp). Policy: `allow zygote shell_data_file:dir mounton` (no neverallow on it).
Considered and left: `/proc/stat` is closed to apps (side channel; top/htop show no CPU,
Boehm GC warns) — would need a separate SELinux domain for the Nix app; `/run`, `/var`
don't exist — `XDG_RUNTIME_DIR` → app dir (environment, no ROM change); `/etc/passwd`
for static Go/musl programs — zygote may not write app-labelled files, nss_wrapper
covers glibc programs.

## Build 9 results on the phone (2026-11-15) and fixes for build 10

Native /nix works on build 9 (first OTA via the Updater app, phone stays locked):
native session without proot, glibc programs + threads (the 5 seccomp calls pass),
`/usr/bin/env`, `/etc/resolv.conf` (Quad9, Cloudflare), home-manager bootstrap (after
phone-side fixes: no HM man page, per-user profile dirs, static Nix).

Two ROM gaps, both SELinux:

- **`/dev/shm` not mounted.** Zygote logged `nix: tmpfs on /dev/shm
  (u:object_r:app_data_file:s0:c…) failed: Permission denied`, avc `zygote
  app_data_file:filesystem relabelfrom`. A `context=` mount checks relabelfrom and
  mount against the new label too. Found only after restarting the app: the audit
  "granted" spam had rotated the main log buffer past the app's start. Fix:
  `allow zygote app_data_file:filesystem { mount relabelfrom relabelto };`
  (domain.te's filesystem neverallow excludes zygote; app_data_file isn't an fs_type).
- **Terminal ioctls.** glibc ≥ 2.42 implements tcgetattr/tcsetattr with
  TCGETS2/TCSETS2* (0x542a–0x542d); domain.te allows only `unpriv_tty_ioctls`
  (TCGETS/TCSETS*) on devpts → no bash prompt/line editing, Nix's builder failed
  "getting pseudoterminal attributes: Permission denied" (also the real cause of
  nix-on-droid #495 under proot). Fix: `allowxperm untrusted_app_all
  devpts:chr_file ioctl { TCGETS2 TCSETS2 TCSETSW2 TCSETSF2 };` (only pty
  neverallow: TIOCSTI).
