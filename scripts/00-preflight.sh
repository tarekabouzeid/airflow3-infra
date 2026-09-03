#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

log "Checking required tools..."
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
for t in docker kind helm kubectl jq vault; do need "$t"; done

log "docker:  $(docker --version)"
log "kind:    $(kind --version)"
log "helm:    $(helm version --short 2>/dev/null || helm version)"
log "kubectl: $(kubectl version --client -o json | jq -r '.clientVersion.gitVersion')"

log "Checking Docker daemon is reachable..."
docker info >/dev/null 2>&1 || die "Docker daemon not reachable - is Docker Desktop / dockerd running?"

log "Checking Docker memory allocation (need >= 12GiB for 3 clusters)..."
MEM_BYTES=$(docker info --format '{{.MemTotal}}')
MEM_GIB=$(( MEM_BYTES / 1024 / 1024 / 1024 ))
log "Docker reports ${MEM_GIB}GiB total memory"
if (( MEM_GIB < 12 )); then
  warn "Docker has less than 12GiB - 3 clusters (Argo CD + Vault + Airflow x2 + Spark) may struggle."
fi

log "Preflight OK."
