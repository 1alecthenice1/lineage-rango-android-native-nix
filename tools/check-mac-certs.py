#!/usr/bin/env python3
"""Check the SELinux certificate tables of a signed target-files zip.

  check-mac-certs.py <target_files.zip> <otatools.zip> [our platform.x509.pem]
  check-mac-certs.py --list <unsigned target_files.zip> <otatools.zip>   (pre-check)

SELinux gives an app its domain (platform_app, bluetooth, ...) by matching the
APK's signing certificate against */etc/selinux/*_mac_permissions.xml.
sign_target_files_apks must rewrite those tables from the test certs to ours;
it reads the old certs by RELATIVE path and silently skips missing ones, so a
run from the wrong directory leaves the test certs in (2026-11-14: SystemUI
lost platform_app → "failed to set system property … Permission denied" →
RescueParty boot loop on every fresh install).

Fails if any test cert shipped in otatools.zip (build/make/…/security,
vendor/lineage/…/security) is still listed, and — given our platform cert —
if seinfo "platform" in plat_mac_permissions.xml is not exactly that cert.
"""
import base64
import re
import sys
import zipfile


def der_hex(pem_text):
    body = "".join(l for l in pem_text.splitlines() if l and not l.startswith("-----"))
    return base64.b64decode(body).hex()


def list_test_certs(tf, ota):
    """--list: names of the test certs (e.g. platform, nfc) the UNSIGNED target-files'
    mac_permissions tables use — each needs a key mapping before signing starts."""
    with zipfile.ZipFile(ota) as z:
        test = {re.sub(r"\.x509\.pem$", "", n): der_hex(z.read(n).decode()) for n in z.namelist()
                if re.search(r"/security/[^/]+\.x509\.pem$", n)}
    used = set()
    with zipfile.ZipFile(tf) as z:
        for n in z.namelist():
            if n.endswith("mac_permissions.xml"):
                low = z.read(n).decode().lower()
                used |= {name for name, cert in test.items() if cert in low}
    for name in sorted(used):
        print(name)


def main():
    if sys.argv[1] == "--list":
        return list_test_certs(sys.argv[2], sys.argv[3])
    tf, ota = sys.argv[1], sys.argv[2]
    ours = sys.argv[3] if len(sys.argv) > 3 else None
    with zipfile.ZipFile(ota) as z:
        test = {n: der_hex(z.read(n).decode()) for n in z.namelist()
                if re.search(r"/security/[^/]+\.x509\.pem$", n)}
    if not test:
        sys.exit("✗ no test certificates found in %s" % ota)
    bad, tables, platform = [], 0, []
    pair = re.compile(r'<signer\s+signature="([0-9a-fA-F]+)"\s*>\s*<seinfo\s+value="([^"]+)"', re.S)
    with zipfile.ZipFile(tf) as z:
        for n in z.namelist():
            if not n.endswith("mac_permissions.xml"):
                continue
            tables += 1
            xml = z.read(n).decode()
            low = xml.lower()
            for name, cert in test.items():
                if cert in low:
                    bad.append("%s still lists test cert %s" % (n, name))
            if n == "SYSTEM/etc/selinux/plat_mac_permissions.xml":
                platform = [s.lower() for s, v in pair.findall(xml) if v == "platform"]
    if tables == 0:
        sys.exit("✗ no mac_permissions.xml in %s" % tf)
    if bad:
        sys.exit("✗ " + "\n✗ ".join(bad))
    if ours:
        want = der_hex(open(ours).read())
        if platform != [want]:
            sys.exit("✗ seinfo platform in plat_mac_permissions.xml is not our platform cert")
    print("✓ %d mac_permissions tables: no test certs%s" %
          (tables, ", seinfo platform = our platform cert" if ours else ""))


if __name__ == "__main__":
    main()
