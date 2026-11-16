#!/usr/bin/env bash
# Point the VM's SSH firewall rule at the build host's current public IP (after a VPN
# reconnected to a different server and SSH to the VM times out).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fw_allow_pro || fail "firewall update"
ok "done"
