#!/usr/bin/env bash
# Standard KIND "local registry" pattern: https://kind.sigs.k8s.io/docs/user/local-registry/
# One registry:2 container, shared by all 3 clusters via the containerd mirror patch already
# baked into kind/*.yaml (containerdConfigPatches).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

reg_name="${LOCAL_REGISTRY_NAME}"
reg_port="${LOCAL_REGISTRY_PORT}"

if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
  log "starting local registry container ${reg_name} on port ${reg_port}..."
  docker run -d --restart=always -p "127.0.0.1:${reg_port}:5000" --network bridge --name "${reg_name}" registry:2
else
  log "registry container ${reg_name} already running"
fi

# Connect the registry to the shared kind network (idempotent - ignore "already exists").
docker network connect kind "${reg_name}" 2>/dev/null || true

# Document the local registry per the kind guide, so `kubectl` tooling that looks for it behaves
# consistently. Applied to every cluster.
for c in af-mgmt af-work-a af-work-b; do
  ctx="$(kctx "$c")"
  log "documenting local registry hosting on ${ctx}..."
  cat <<YAML | kubectl --context "${ctx}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
YAML
done

log "Local registry ready at localhost:${reg_port} (push from host; nodes resolve it via containerd mirror)."
