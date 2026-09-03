#!/usr/bin/env bash
# Shared helpers for every scripts/*.sh. Sourced, not executed.
set -euo pipefail

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[1;33m[%s] WARN\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

repo_root() {
  (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
}

REPO_ROOT="$(repo_root)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/versions.env"

mkdir -p "${REPO_ROOT}/.local"

retry() {
  local max=$1; shift
  local n=1
  until "$@"; do
    if (( n >= max )); then die "command failed after ${n} attempts: $*"; fi
    warn "attempt ${n}/${max} failed: $* - retrying in $((n*2))s"
    sleep $((n*2))
    n=$((n+1))
  done
}

# Container-name based addressing on the shared `kind` Docker network. Never hardcode IPs:
# KIND creates one Docker network named "kind" shared by every cluster on the host, and each
# control-plane container is reachable by its own container name from any other container on
# that network (Docker's embedded DNS), including from pods (via node -> Docker DNS forwarding).
cluster_api_server() {
  local cluster=$1
  echo "https://${cluster}-control-plane:6443"
}

kctx() {
  echo "kind-$1"
}

wait_for_rollout() {
  local ctx=$1 ns=$2 kind=$3 name=$4 timeout=${5:-300s}
  kubectl --context "${ctx}" -n "${ns}" rollout status "${kind}/${name}" --timeout="${timeout}"
}

kind_cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$1"
}
