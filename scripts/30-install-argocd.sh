#!/usr/bin/env bash
# The ONE imperative step. Everything after this is GitOps: Argo CD manages itself
# (platform/bootstrap/app-argocd-self.yaml) once the root Application is applied.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

ctx="$(kctx af-mgmt)"

log "adding argo helm repo..."
helm repo add argo "${ARGOCD_CHART_REPO}" >/dev/null
helm repo update argo >/dev/null

log "installing Argo CD ${ARGOCD_CHART_VERSION_START} on af-mgmt (namespace argocd)..."
helm upgrade --install argocd argo/argo-cd \
  --version "${ARGOCD_CHART_VERSION_START}" \
  --kube-context "${ctx}" \
  --namespace argocd --create-namespace \
  -f bootstrap/argocd-values.yaml \
  --wait --timeout 10m

wait_for_rollout "${ctx}" argocd deployment argocd-server 5m

log "applying the root Application (app-of-apps)..."
kubectl --context "${ctx}" apply -f bootstrap/root-app.yaml

log "Argo CD installed. Fetch the initial admin password with:"
log "  kubectl --context ${ctx} -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
