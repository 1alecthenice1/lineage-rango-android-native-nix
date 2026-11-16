#!/usr/bin/env bash
# Check a fresh build VM: NixOS, /src really mounted (not the empty mountpoint),
# backing device, podman, cores/RAM. Exit 1 on any problem.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
vm_ssh 'set -u; bad=0
  nixos-version
  if mountpoint -q /src; then echo "/src: $(findmnt -no SOURCE,FSTYPE,SIZE /src)"; else echo "✗ /src NOT mounted"; bad=1; fi
  systemctl is-active -q src-disk || { echo "✗ src-disk: $(systemctl is-active src-disk)"; journalctl -u src-disk -b --no-pager | tail -15; bad=1; }
  [ -w /src ] || { echo "✗ /src not writable"; bad=1; }
  podman --version || bad=1
  echo "cores $(nproc), RAM $(free -g | awk "/Mem:/{print \$2}") GB"
  exit $bad' && ok "VM ok" || fail "VM check failed"
