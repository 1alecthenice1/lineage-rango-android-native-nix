#!/usr/bin/env bash
# One-time GCP setup (run on the build host, after `gcloud auth login`):
# new project for the LineageOS builds, linked to your billing account, Compute
# Engine enabled, and a $30/month budget (override: BUDGET=<USD>) with e-mail alerts at 50/90/100 %.
# A budget only ALERTS, it doesn't stop spending — steps/vm-delete.sh after
# every build is what keeps the cost down.
#   ./steps/gcp-setup.sh [project-id]
set -euo pipefail
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }
cd "$(dirname "$0")/.."
gcloud() { "$(nix build --no-link --print-out-paths --inputs-from "$(dirname "$0")/.." nixpkgs#google-cloud-sdk)/bin/gcloud" "$@"; }

acct=$(gcloud config get-value account 2>/dev/null)
[ -n "$acct" ] || fail "not logged in — run: gcloud auth login"
ok "logged in as $acct"

# reuse the project of an earlier (partial) run instead of creating another one
[ -f .gcp.env ] && . ./.gcp.env
cur=$(gcloud config get-value project 2>/dev/null)
case "$cur" in lineage-rango-*) : "${PROJECT:=$cur}" ;; esac
project=${1:-${PROJECT:-lineage-rango-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')}}
if gcloud projects describe "$project" >/dev/null 2>&1; then
  ok "project $project exists"
else
  gcloud projects create "$project" --name="LineageOS rango build" || fail "project create"
  ok "created project $project"
fi
gcloud config set project "$project" >/dev/null
echo "PROJECT=$project" > .gcp.env

# one listing, retried: gcloud's shared OAuth client sometimes hits Google's
# per-minute quota (HTTP 429) on the billing API
for try in 1 2 3 4 5; do
  if accounts=$(gcloud billing accounts list --filter=open=true --format='value(name,displayName)' 2>/tmp/gcp-billing.err); then break; fi
  grep -q 429 /tmp/gcp-billing.err || { cat /tmp/gcp-billing.err; fail "billing accounts list"; }
  echo "billing API busy (429), retry $try/5 in 30 s…"; sleep 30
done
[ -n "${accounts:-}" ] || fail "no open billing account — reopen/create one at console.cloud.google.com/billing, then rerun (project $project is kept)"
echo "Billing accounts:"; printf '%s\n' "$accounts" | nl
n=$(printf '%s\n' "$accounts" | wc -l)
if [ "$n" = 1 ]; then pick=1; else read -rp "Which one (number)? " pick; fi
billing=$(printf '%s\n' "$accounts" | sed -n "${pick}p" | cut -f1)
billing=${billing#billingAccounts/}
gcloud billing projects link "$project" --billing-account="$billing" >/dev/null || fail "billing link"
ok "billing account $billing linked"

gcloud services enable compute.googleapis.com billingbudgets.googleapis.com || fail "enable APIs"
ok "Compute Engine + Budgets API enabled"

if gcloud billing budgets list --billing-account="$billing" --format='value(displayName)' | grep -qx "lineage-rango"; then
  ok "budget lineage-rango exists"
else
  gcloud billing budgets create --billing-account="$billing" --display-name=lineage-rango \
    --budget-amount="${BUDGET:-30}USD" --filter-projects="projects/$project" \
    --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0 \
    || fail "budget create"
  ok "budget: ${BUDGET:-30} USD/month, alerts at 50/90/100 % (to the billing account's admins)"
fi
# the default network opens SSH + RDP to the whole internet; our VM gets its own
# rule (the build host's IP only, steps/lib.sh fw_allow_pro)
for r in default-allow-ssh default-allow-rdp; do
  gcloud compute firewall-rules describe "$r" >/dev/null 2>&1 &&
    gcloud compute firewall-rules delete "$r" --quiet >/dev/null && ok "removed firewall rule $r"
done
echo "PROJECT=$project" > .gcp.env
ok "saved project id to .gcp.env"
