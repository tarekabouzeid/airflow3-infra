#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

for c in af-mgmt af-work-a af-work-b; do
  if kind_cluster_exists "$c"; then
    log "deleting cluster $c ..."
    kind delete cluster --name "$c"
  fi
done

if docker inspect "${LOCAL_REGISTRY_NAME}" >/dev/null 2>&1; then
  log "removing local registry container..."
  docker rm -f "${LOCAL_REGISTRY_NAME}" >/dev/null
fi

log "Teardown complete. Vault keys (if any) remain at .local/vault-keys.json - remove manually if desired."
