#!/usr/bin/env python3
"""check-fw-descriptors.py <avbtool info_image output of vbmeta.img> <target_files.zip>

Every bootloader firmware image in RADIO/ (all but modem) must have a hash
descriptor in vbmeta whose digest = sha256(salt + image), like Google's stock
vbmeta. Without them the Pixel 10 bootloader refuses `fastboot flashing lock`
("invalid android images, skip locking", 2026-11-14).
"""
import hashlib, re, sys, zipfile

info = open(sys.argv[1]).read()
desc = {}
for block in info.split("Hash descriptor:")[1:]:
    f = dict(re.findall(r"^\s+([A-Za-z ]+):\s+(\S+)", block, re.M))
    if "Partition Name" in f:
        desc[f["Partition Name"]] = (f.get("Salt", ""), f.get("Digest", ""))
bad, n = [], 0
with zipfile.ZipFile(sys.argv[2]) as z:
    for name in sorted(z.namelist()):
        m = re.fullmatch(r"RADIO/(.+)\.img", name)
        if not m or m.group(1) == "modem":
            continue
        n += 1
        p = m.group(1)
        if p not in desc:
            bad.append("vbmeta has no descriptor for firmware partition %s" % p)
            continue
        salt, dig = desc[p]
        if hashlib.sha256(bytes.fromhex(salt) + z.read(name)).hexdigest() != dig:
            bad.append("vbmeta digest for %s does not match RADIO/%s.img" % (p, p))
if n == 0:
    sys.exit("✗ no firmware images in RADIO/")
if bad:
    sys.exit("✗ " + "\n✗ ".join(bad))
print("✓ vbmeta covers all %d bootloader firmware partitions (digests match RADIO/)" % n)
