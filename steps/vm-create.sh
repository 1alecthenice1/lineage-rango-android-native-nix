#!/usr/bin/env bash
# Create the build VM (spot, stops instead of being deleted if Google reclaims
# it) from our NixOS image (family lineage-builder, steps/image-build.sh), or
# with IMAGE=debian a stock Debian 12 VM to build that image on.
# Costs money from here until steps/vm-delete.sh.
#   MACHINE=c2d-highcpu-56 DATA_GB=450 ZONE=us-central1-a ./steps/vm-create.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"
# 56 vCPU / 112 GB (quota CPUS_ALL_REGIONS 64 since 2026-11-13)
MACHINE=${MACHINE:-c2d-highcpu-56}
DATA_GB=${DATA_GB:-450}
# pd-ssd: ~3x the IOPS of pd-balanced for ~+$0.50 per build; same SSD quota
DATA_TYPE=${DATA_TYPE:-pd-ssd}
# local NVMe SSDs (375 GB each, RAID 0 as /src) instead of the data disk: much
# faster, no SSD quota, but lost if the spot VM is preempted (then the VM is
# deleted and the build starts over). LOCAL_SSD=0 = persistent data disk.
# c2d-highcpu-56 accepts only 0, 4 or 8 local SSDs → 4 = 1.5 TB RAID 0
LOCAL_SSD=${LOCAL_SSD:-4}
gcloud compute instances describe "$NAME" --zone "$ZONE" >/dev/null 2>&1 && fail "$NAME already exists (steps/vm-delete.sh first)"
if [ "${IMAGE:-}" = debian ]; then
  img=image-family=debian-12,image-project=debian-cloud
else
  gcloud compute images describe-from-family lineage-builder >/dev/null 2>&1 ||
    fail "no lineage-builder image yet: IMAGE=debian $0, then steps/image-build.sh"
  img=image-family=lineage-builder,image-project=$PROJECT
fi
fw_allow_pro || fail "firewall rule"
if [ "$LOCAL_SSD" -gt 0 ] && [ "${IMAGE:-}" != debian ]; then
  disk_args=(); for _ in $(seq "$LOCAL_SSD"); do disk_args+=(--local-ssd=interface=NVME); done
  term=DELETE   # local SSD contents don't survive a stop anyway
else
  disk_args=(--create-disk=device-name=src,size="$DATA_GB",type="$DATA_TYPE",auto-delete=yes)
  term=STOP
fi
gcloud compute instances create "$NAME" --zone "$ZONE" --machine-type "$MACHINE" \
  --provisioning-model=SPOT --instance-termination-action="$term" \
  --create-disk=boot=yes,device-name=boot,"$img",size=50,type=pd-balanced,auto-delete=yes \
  "${disk_args[@]}" \
  --tags=lineage-builder \
  --metadata=enable-oslogin=FALSE,ssh-keys="builder:$(cat "$HOME/.ssh/gce-builder.pub")" \
  || fail "instance create"
rm -f "$HOME/.ssh/known_hosts.gce"
ip=$(vm_ip)
if [ "$term" = DELETE ]; then ok "created $NAME ($MACHINE, ${LOCAL_SSD}x375 GB local NVMe) at $ip"
else ok "created $NAME ($MACHINE, ${DATA_GB} GB $DATA_TYPE data) at $ip"; fi
for i in $(seq 30); do vm_ssh true 2>/dev/null && { ok "SSH works"; exit 0; }; sleep 10; done
fail "no SSH after 5 min"
