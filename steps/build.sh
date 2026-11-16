#!/usr/bin/env bash
# Start / watch the LineageOS build on the VM (tmux session "build", log
# /src/build.log; survives SSH drops and spot stop/start = rerun resumes).
# BUILD_ENV=container (default): in the Ubuntu container from vm/Containerfile
# (rootless podman, /src mounted); BUILD_ENV=fhs: in the NixOS aosp-env.
#   ./steps/build.sh          start (or reattach if running)
#   ./steps/build.sh status   last log lines
#   SYNC=0 ./steps/build.sh   rebuild on the same VM without repo sync (incremental)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
case "${1:-start}" in
  status) vm_ssh 'tail -c 20000 /src/build.log | tr "\r" "\n" | grep -v "^\s*$" | tail -n 15; echo; grep "^===" /src/build.log | tail -4' ;;
  start)
    rsync -a --delete -e "ssh ${SSH_OPTS[*]}" vm/remote-build.sh vm/Containerfile patches extras "builder@$(vm_ip):/src/" || fail "copy"
    if [ "${BUILD_ENV:-container}" = container ]; then
      # same uid inside (keep-id) so /src stays builder-owned; HOME on /src
      # seccomp unconfined: Bazel's linux-sandbox (kernel build) creates nested namespaces;
      # no pids limit + host ulimits: podman's default 2048 pids broke 56 parallel javac/turbine
      run='mkdir -p /src/home /src/ctx && podman build -q -t lineage-env -f /src/Containerfile /src/ctx >/dev/null && podman run --rm --userns=keep-id --security-opt seccomp=unconfined --pids-limit=-1 --ulimit host -e HOME=/src/home -e SYNC='"${SYNC:-1}"' -v /src:/src -w /src lineage-env bash /src/remote-build.sh'
    else
      run='aosp-env /src/remote-build.sh'
    fi
    vm_ssh "tmux has-session -t build 2>/dev/null && echo 'already running' ||
            { [ ! -s /src/build.log ] || mv /src/build.log /src/build.log.\$(date +%s); } &&
            tmux new -d -s build 'set -o pipefail; ( $run ) 2>&1 | tee -a /src/build.log'" || fail "start"
    ok "build running in tmux on the VM — ./steps/build.sh status" ;;
  *) fail "usage: $0 [start|status]" ;;
esac
