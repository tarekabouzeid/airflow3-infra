#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

for c in af-mgmt af-work-a af-work-b; do
  if kind_cluster_exists "$c"; then
    log "cluster $c already exists, skipping"
  else
    log "creating cluster $c ..."
    retry 3 kind create cluster --config "kind/${c}.yaml"
  fi
done

log "Clusters:"
kind get clusters

log "Verifying cross-cluster addressing on the shared 'kind' Docker network..."
for c in af-mgmt af-work-a af-work-b; do
  docker network inspect kind --format '{{range .Containers}}{{.Name}} {{end}}' | grep -q "${c}-control-plane" \
    || die "container ${c}-control-plane is not on the 'kind' network - cross-cluster addressing will fail"
done
log "All 3 control-plane containers share the 'kind' Docker network."
