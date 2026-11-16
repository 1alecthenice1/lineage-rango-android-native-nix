#!/usr/bin/env bash
# Pre-sign check of an UNSIGNED build (after fetch.sh, before the 3½ h signing):
# did every one of our patches/extras land in the target-files?
#   ./steps/check-build.sh <build dir>        (dir with lineage_rango-target_files.zip)
# Read-only. Exits 1 on any missing item. Items marked (build 11+) are the
# nix_app domain, phantom-killer default and GrapheneOS fingerprint fix; on a
# build 10 zip they fail — expected (that is how the script was validated).
set -euo pipefail
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }
cd "$(dirname "$0")/.."
d=$(realpath "${1:?usage: $0 <build dir>}")
tf=$(ls "$d"/*-target_files*.zip 2>/dev/null | grep -v signed | head -1) || true
[ -n "$tf" ] || fail "no unsigned *-target_files.zip in $d"
pkg() { nix build --no-link --print-out-paths --inputs-from "$(dirname "$0")/.." "nixpkgs#$1"; }
"$(pkg python3)/bin/python3" -I - "$tf" extras/sepolicy/certs/nix-on-droid-fdroid.x509.pem <<'EOF'
import base64, re, sys, zipfile, io
tf, pem = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(tf)
names = set(z.namelist())
fails = 0
def r(cond, msg):
    global fails
    fails += not cond
    print(("PASS  " if cond else "FAIL  ") + msg, flush=True)
def read(n): return z.read(n).decode(errors="replace")
def dex_has(apk_member, needle):
    """class/string present in any classes*.dex of an APK/JAR inside the target-files"""
    with zipfile.ZipFile(io.BytesIO(z.read(apk_member))) as a:
        return any(needle.encode() in a.read(m) for m in a.namelist() if re.match(r"classes\d*\.dex$", m))

cil = "".join(read(n) for n in names if n.endswith("_sepolicy.cil") and "/mapping/" not in n)
seapp = "".join(read(n) for n in names if n.endswith("seapp_contexts"))
macp = {n: read(n).lower() for n in names if n.endswith("mac_permissions.xml")}
props = "".join(read(n) for n in names if n.endswith("/build.prop"))

print("== native /nix (build 7–10 items)")
r("(type nix_mnt_file)" in cil and "(allow zygote nix_mnt_file (dir (getattr mounton)))" in cil, "sepolicy: zygote may mount on /nix")
r("(allow zygote app_data_file (filesystem (mount relabelfrom relabelto)))" in cil, "sepolicy: /dev/shm context= mount for zygote")
r("ro.nix.package=com.termux.nix" in props, "ro.nix.package set")
r("ROOT/nix/README" in names and "ROOT/usr/bin/README" in names, "/nix and /usr/bin mountpoints in the root image")
r("SYSTEM/etc/resolv.conf" in names, "/etc/resolv.conf in the image")

print("== build 11+: nix_app domain")
r("(type nix_app)" in cil, "sepolicy: nix_app type exists")
r("(allow nix_app app_data_file (file (link)))" in cil, "sepolicy: nix_app may hard-link its own files")
# app ptys are untrusted_app_all_devpts (create_pty), NOT devpts — build 10's rule on
# devpts never applied (2026-11-16: bash stayed non-interactive)
r(re.search(r"\(allowx nix_app untrusted_app_all_devpts \(ioctl chr_file \(\(range 0x542a 0x542d\)\)\)\)", cil) is not None, "sepolicy: nix_app gets TCGETS2..TCSETSF2 on its ptys (untrusted_app_all_devpts)")
r("(allowx untrusted_app_all devpts" not in cil, "sepolicy: build 10's ineffective devpts rule is gone")
r(re.search(r"^user=_app seinfo=nix_app name=com\.termux\.nix domain=nix_app type=app_data_file levelFrom=all", seapp, re.M) is not None, "seapp_contexts: nix_app entry")
body = "".join(l for l in open(pem).read().splitlines() if l and not l.startswith("-----"))
cert = base64.b64decode(body).hex()
hit = [n for n, x in macp.items() if cert in x and 'seinfo value="nix_app"' in x]
r(bool(hit), "mac_permissions: Nix-on-Droid F-Droid cert → seinfo nix_app" + (f" ({hit[0]})" if hit else ""))
r("persist.sys.fflag.override.settings_enable_monitor_phantom_procs=false" in props, "build.prop: phantom process killer off by default")

print("== build 11+: fingerprint fix moved to Settings (GrapheneOS)")
settings = [n for n in names if re.search(r"/priv-app/Settings/Settings\.apk$", n)]
r(bool(settings), "Settings.apk found" + (f" ({settings[0]})" if settings else ""))
if settings:
    r(dex_has(settings[0], "Lcom/google/hardware/biometrics/sidefps/IFingerprintExt;"), "Settings: IFingerprintExt AIDL class compiled in")
    r(dex_has(settings[0], "resumeEnroll"), "Settings: resumeEnroll present")
svc = [n for n in names if n.endswith("/framework/services.jar")]
if svc:
    r(not dex_has(svc[0], "com.google.hardware.biometrics.sidefps.IFingerprintExt"), "services.jar: our old frameworks/base resume code is gone")
else:
    r(False, "services.jar not found")

print("ALL PASSED" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
EOF
