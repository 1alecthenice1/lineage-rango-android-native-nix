#!/usr/bin/env bash
# Download the unsigned build (target-files + otatools) to the build host for signing.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
# under ~/phone/rango: re-buildable, no need to back it up
dest=${DEST:-$HOME/phone/rango/builds/$(date +%F)}
# the VM's address once (gcloud), with retries — every later step uses it
for t in 1 2 3 4 5 6; do ip=$(vm_ip 2>/dev/null) && [ -n "$ip" ] && break; echo "no VM address yet (try $t)"; sleep 20; done
[ -n "${ip:-}" ] || fail "cannot reach gcloud / the VM"
ssh_vm() { local t; for t in 1 2 3 4 5; do ssh "${SSH_OPTS[@]}" "builder@$ip" "$@" && return 0; sleep 20; done; return 1; }
# the build host's Wi-Fi drops the link under sustained load (beacon loss, 2026-11-13) →
# resume with --partial and retry instead of failing the whole fetch
get() {
  local t
  for t in 1 2 3 4 5 6 7 8 9 10; do
    rsync -e "ssh ${SSH_OPTS[*]}" --partial --info=progress2 "builder@$ip:$1" "$dest/" && return 0
    echo "rsync of $1 broke (try $t), resuming in 30 s"; sleep 30
  done
  return 1
}
mkdir -p "$dest"
# one fetch per folder: on 2026-11-15 a stopped rsync's script retried while a
# second fetch ran, both writing the same files (hashes still matched by luck)
exec 9>"$dest/.fetch.lock"
flock -n 9 || fail "another fetch is already writing to $dest"
# end-to-end check: hashes computed on the VM must match the local copies
vm_check() {
  local p remote local_h
  while read -r p; do
    case "$p" in /*) ;; *) p=/src/lineage/$p ;; esac
    remote=$(ssh_vm "sha256sum '$p'" | cut -d' ' -f1)
    local_h=$(sha256sum "$dest/$(basename "$p")" | cut -d' ' -f1)
    [ -n "$remote" ] && [ "$remote" = "$local_h" ] || fail "$(basename "$p"): VM $remote ≠ local $local_h"
  done < "$dest/.files"
  ok "hashes match the VM"
}
# target-files from $OUT; otatools.zip from soong's intermediates (Android 17)
# FROM=/src/<dir>: fetch a copy set aside on the VM (target-files + otatools.zip
# + manifest-pinned.xml), e.g. while the next incremental build runs
if [ -n "${FROM:-}" ]; then
  ssh_vm "ls $FROM/*-target_files*.zip $FROM/otatools.zip" > "$dest/.files" || fail "nothing in $FROM"
  [ "$(grep -c . "$dest/.files")" = 2 ] || fail "expected target-files + otatools.zip in $FROM"
  while read -r p; do
    get "$p" || fail "rsync $p"
  done < "$dest/.files"
  rsync -e "ssh ${SSH_OPTS[*]}" "builder@$ip:$FROM/manifest-pinned.xml" "$dest/" || fail "manifest"
  vm_check
  ( cd "$dest" && sha256sum *.zip > SHA256SUMS ) && ok "in $dest" && cat "$dest/SHA256SUMS"
  exit 0
fi
ssh_vm 'cd /src/lineage && ls out/target/product/rango/obj/PACKAGING/target_files_intermediates/*-target_files*.zip &&
        find out/soong/.intermediates/build/make/tools/otatools_package out/target/product/rango -name otatools.zip | head -1' > "$dest/.files" || fail "build output not found"
[ "$(grep -c . "$dest/.files")" = 2 ] || fail "expected target-files + otatools.zip, got: $(cat "$dest/.files")"
while read -r p; do
  get "/src/lineage/$p" || fail "rsync $p"
done < "$dest/.files"
rsync -e "ssh ${SSH_OPTS[*]}" "builder@$ip:/src/manifest-pinned.xml" "$dest/" || fail "manifest"
vm_check
( cd "$dest" && sha256sum *.zip > SHA256SUMS ) && ok "in $dest" && cat "$dest/SHA256SUMS"
