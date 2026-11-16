# shared by the steps/*.sh scripts
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }
cd "$(dirname "$0")/.." || exit 1
[ -f .gcp.env ] || fail "no .gcp.env — run steps/gcp-setup.sh first"
. ./.gcp.env
NAME=${NAME:-lineage-builder}
ZONE=${ZONE:-us-central1-a}
_sdk() { nix build --no-link --print-out-paths --inputs-from "$(dirname "$0")/.." "nixpkgs#$1"; }
gcloud() { "$(_sdk google-cloud-sdk)/bin/gcloud" --project "$PROJECT" "$@"; }
vm_ip() { gcloud compute instances describe "$NAME" --zone "$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)'; }
# own known_hosts: every new VM has a new host key
SSH_OPTS=(-i "$HOME/.ssh/gce-builder" -o UserKnownHostsFile="$HOME/.ssh/known_hosts.gce"
          -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=30)
vm_ssh() { ssh "${SSH_OPTS[@]}" "builder@$(vm_ip)" "$@"; }
# SSH to the VM only from this machine's current public IPv4 (rerun
# steps/ssh-allow.sh when it changes, e.g. after a VPN reconnect)
fw_allow_pro() {
  local me; me=$(curl -4fsS --max-time 15 https://api.ipify.org) || { echo "can't find this machine's public IP" >&2; return 1; }
  if gcloud compute firewall-rules describe lineage-ssh >/dev/null 2>&1; then
    gcloud compute firewall-rules update lineage-ssh --source-ranges "$me/32" --quiet >/dev/null
  else
    gcloud compute firewall-rules create lineage-ssh --network default --direction INGRESS \
      --allow tcp:22 --source-ranges "$me/32" --target-tags lineage-builder --quiet >/dev/null
  fi && echo "SSH allowed from $me only"
}
