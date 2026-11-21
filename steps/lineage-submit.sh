#!/usr/bin/env bash
# Prepare the LineageOS Gerrit submission of the fingerprint enrollment fix
# (LineageOS issue #8005) — stops BEFORE pushing; the push is the user's step.
#   ./steps/lineage-submit.sh <gerrit-username> <email verified on your Gerrit account>
# The email becomes committer of both commits and author of ours (Gerrit checks
# both against the account; it is public in review/git history). Not stored here.
# Builds ~/lineage-submit/Settings on top of current lineage-24.0 with:
#   1. GrapheneOS's commit 30dae1da04 (Dmitry Muhomor, 2024), cherry-picked with
#      original authorship, LineageOS-style subject, "(cherry picked from …)"
#   2. our fallback commit (framework vendor strings), tested on rango
# Change-Ids come from Gerrit's commit-msg hook. Push command printed at the end.
set -euo pipefail
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }
user=${1:?usage: $0 <gerrit-username> <email verified on Gerrit>}
email=${2:?usage: $0 <gerrit-username> <email verified on Gerrit>}
repo=$(cd "$(dirname "$0")/.." && pwd)
dir=$HOME/lineage-submit/Settings
gos=30dae1da048e7ed64b1d0af4bb885fe4ad13e343

[ -e "$dir" ] && fail "$dir exists — remove it first (rm -rf $dir) to start clean"
mkdir -p "$(dirname "$dir")"
echo "cloning LineageOS Settings (lineage-24.0, last 50 commits)…"
git clone -q --depth 50 -b lineage-24.0 https://github.com/LineageOS/android_packages_apps_Settings "$dir"
cd "$dir"
git config user.name 1alecthenice1
git config user.email "$email"   # committer of both commits
curl -fsSL -o .git/hooks/commit-msg https://review.lineageos.org/tools/hooks/commit-msg && chmod +x .git/hooks/commit-msg

# 1: GrapheneOS's commit, authorship kept (git am keeps From:/Date:)
git am -q --3way "$repo"/patches/packages/apps/Settings/0001-*.patch || fail "GrapheneOS patch no longer applies to lineage-24.0 — rebase needed"
git commit -q --amend -F - <<EOF
Settings: Fix fingerprint enrollment on Google devices with side FP scanner

Pixel side-mounted fingerprint HALs (Goodix "milan" on felix, rango, ...)
pause an enrollment after a threshold of rejected touches and report
vendor acquired code 1000. Google's Settings then asks the user to move
their finger and resumes through the HAL's binder extension
com.google.hardware.biometrics.sidefps.IFingerprintExt#resumeEnroll().
Nothing in AOSP makes that call, so enrollment hangs for good.

Hook into AOSP's SfpsEnrollmentFeature: on the pause, show the vendor
message in a dialog and call resumeEnroll() when it is acknowledged.

Fixes: https://gitlab.com/LineageOS/issues/android/-/issues/8005
Test: rango: repeated touches on one spot pause the enrollment, the
      dialog appears, OK resumes it, enrollment completes.
(cherry picked from commit $gos
 https://github.com/GrapheneOS/platform_packages_apps_Settings)
EOF
[ "$(git log -1 --format=%an)" = "Dmitry Muhomor" ] || fail "authorship of the cherry-pick got lost"

# 2: our fallback
git am -q --3way "$repo"/patches/packages/apps/Settings/0002-*.patch || fail "fallback patch doesn't apply"
# ours: author = the Gerrit account (the patch file carries the GitHub noreply address)
git commit -q --amend --reset-author -F - <<'EOF'
Settings: Fall back to framework vendor fingerprint strings

Settings' own fingerprint_acquired_vendor array is empty unless a device
overlays it for Settings. LineageOS device trees (e.g. rango) overlay and
translate it for the framework only, so getVendorString(ctx, 0) threw at
the moment the HAL paused the enrollment. Use the framework's array when
Settings has none.

Test: rango, LineageOS 24: repeated touches on one spot -> HAL "Report
      pause enrollment message" -> handleOnEnrollmentHelp(1000) -> dialog
      with the framework string -> OK -> HAL "Resume Enrollment process"
      -> enrollment completes.
Assisted-by: LLM
EOF

git log --format='%h author %an <%ae>, committer %cn <%ce>%n    %s%n    %(trailers:key=Change-Id,valueonly)' -2
git log -2 --format=%B | grep -c '^Change-Id: I' | grep -qx 2 || fail "Change-Id missing (commit-msg hook not run?)"
ok "branch ready in $dir (2 commits on lineage-24.0)"
cat <<EOF

Review it:   cd $dir && git show HEAD~1 HEAD
Then push (your SSH key must be added at review.lineageos.org → Settings → SSH Keys):
  git -C $dir push ssh://$user@review.lineageos.org:29418/LineageOS/android_packages_apps_Settings HEAD:refs/for/lineage-24.0%topic=sfps-resume-enroll
EOF
