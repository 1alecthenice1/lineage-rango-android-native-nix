#!/usr/bin/env python3
"""Check every */otacerts.zip in a signed target-files zip.

  check-otacerts.py <target_files.zip> <releasekey.x509.pem>

Fails if an otacerts.zip has duplicate entry names (recovery's ziparchive then
refuses the whole file: "Found duplicate entry", "Failed to load keys", every
sideload aborts with status 2 — builds 7 + 9, 2026-11-15), is empty, or holds any
certificate other than ours. Compares the PEM bodies (base64 DER), no openssl.
"""
import io
import re
import sys
import zipfile


def der_b64(pem):
    m = re.search(rb"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", pem, re.S)
    if not m:
        raise ValueError("no certificate")
    return b"".join(m.group(1).split())


def main():
    tf, ours_path = sys.argv[1], sys.argv[2]
    ours = der_b64(open(ours_path, "rb").read())
    bad = 0
    found = 0
    with zipfile.ZipFile(tf) as z:
        for name in z.namelist():
            if not name.endswith("/otacerts.zip"):
                continue
            found += 1
            inner = zipfile.ZipFile(io.BytesIO(z.read(name)))
            names = inner.namelist()
            dups = sorted({n for n in names if names.count(n) > 1})
            problems = []
            if dups:
                problems.append("duplicate entries " + ", ".join(dups))
            if not names:
                problems.append("no certificates")
            for info in inner.infolist():
                try:
                    if der_b64(inner.read(info)) != ours:
                        problems.append(info.filename + " is not our key")
                except ValueError:
                    problems.append(info.filename + " is not a certificate")
            if problems:
                bad += 1
                print("FAIL %s: %s" % (name, "; ".join(problems)))
            else:
                print("ok   %s: %d entr%s, all our key" % (name, len(names), "y" if len(names) == 1 else "ies"))
    if found == 0:
        print("FAIL no otacerts.zip in " + tf)
        return 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
