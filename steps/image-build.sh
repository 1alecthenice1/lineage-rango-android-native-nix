#!/usr/bin/env bash
# Build our NixOS GCE image (flake output .#image) on a Debian VM and register it
# as image family "lineage-builder". Needed once, and again after changes to
# vm/builder.nix / flake.lock. Build VMs then boot straight into it.
#   IMAGE=debian ./steps/vm-create.sh && ./steps/image-build.sh && ./steps/vm-delete.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ip=$(vm_ip); [ -n "$ip" ] || fail "no VM (IMAGE=debian steps/vm-create.sh)"
vm_ssh 'grep -q debian /etc/os-release' || fail "VM isn't the Debian bootstrap VM"
git diff --quiet HEAD -- vm flake.nix flake.lock || fail "commit vm/ + flake first (the image is built from the committed config)"
rev=$(git rev-parse --short HEAD)
tmp=lineage-image-tmp

step() { printf '\n== %s\n' "$*"; }
step "Nix on the Debian VM"
vm_ssh 'command -v rsync >/dev/null || { sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync git >/dev/null; }
command -v nix >/dev/null || [ -x /nix/var/nix/profiles/default/bin/nix ] || {
  curl -fsSL https://nixos.org/nix/install | sh -s -- --daemon --yes >/tmp/nix-install.log 2>&1 || { tail /tmp/nix-install.log; exit 1; }
}
# no /dev/kvm on GCE AMD VMs: claim "kvm" so the image VM runs (qemu falls back to TCG)
sudo tee /etc/nix/nix.custom.conf >/dev/null <<CONF
experimental-features = nix-command flakes
system-features = kvm nixos-test big-parallel benchmark
max-jobs = auto
CONF
grep -q nix.custom.conf /etc/nix/nix.conf || echo "!include nix.custom.conf" | sudo tee -a /etc/nix/nix.conf >/dev/null
sudo systemctl restart nix-daemon' || fail "nix install"
ok "nix ready"

step "build the image ($rev)"
git ls-files -z | rsync -a --delete --from0 --files-from=- -e "ssh ${SSH_OPTS[*]}" ./ "builder@$ip:lineage-rango/" || fail "copy repo"
vm_ssh '. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  cd lineage-rango && git init -q 2>/dev/null; git add -A >/dev/null 2>&1
  nix build path:.#image --out-link ~/image -L 2>&1 | tail -20; ls -la ~/image/' || fail "image build"
ok "image built"

step "write it to a temporary disk"
gcloud compute disks create "$tmp" --zone "$ZONE" --size 20 --type pd-standard >/dev/null || fail "tmp disk"
gcloud compute instances attach-disk "$NAME" --zone "$ZONE" --disk "$tmp" --device-name imgtmp >/dev/null || fail "attach"
vm_ssh 'set -e; f=$(ls ~/image/*.tar.gz); dev=/dev/disk/by-id/google-imgtmp
  for i in $(seq 20); do [ -e $dev ] && break; sleep 1; done
  tar -xzOf "$f" disk.raw | sudo dd of=$dev bs=4M conv=sparse,fsync status=none
  sudo blockdev --flushbufs $dev' || fail "dd"
gcloud compute instances detach-disk "$NAME" --zone "$ZONE" --disk "$tmp" >/dev/null || fail "detach"
img=lineage-builder-$(date -u +%Y%m%d-%H%M)-$rev
gcloud compute images create "$img" --family lineage-builder --source-disk "$tmp" --source-disk-zone "$ZONE" \
  --guest-os-features UEFI_COMPATIBLE,VIRTIO_SCSI_MULTIQUEUE >/dev/null || fail "image create"
gcloud compute disks delete "$tmp" --zone "$ZONE" --quiet >/dev/null
ok "image $img (family lineage-builder)"
# keep the two newest images
gcloud compute images list --filter="family=lineage-builder" --sort-by=~creationTimestamp --format='value(name)' --no-standard-images |
  tail -n +3 | while read -r old; do gcloud compute images delete "$old" --quiet >/dev/null && echo "deleted old image $old"; done
