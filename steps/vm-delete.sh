#!/usr/bin/env bash
# Delete the build VM and both its disks (auto-delete) — stops all VM costs.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gcloud compute instances delete "$NAME" --zone "$ZONE" --quiet || fail "delete"
gcloud compute firewall-rules delete lineage-ssh --quiet >/dev/null 2>&1 && echo "SSH rule removed"
rm -f "$HOME/.ssh/known_hosts.gce"
left=$(gcloud compute disks list --format='value(name)')
[ -z "$left" ] && ok "VM and disks deleted, nothing left that costs" || fail "disks still exist: $left"
