#!/usr/bin/env bash
# The ONE imperative step. Everything after this is GitOps: Argo CD manages itself
# (platform/bootstrap/app-argocd-self.yaml) once the root Application is applied.
#
# This platform repo AND every tenant repo are private, and Argo CD needs its own read credential
# for each: the platform repo because every Application/ApplicationSet under platform/bootstrap/
# points back at it via HTTPS, and each tenant repo because appset-tenant-airflow.yaml's source 3
# of 3 pulls deploy/airflow/values.yaml straight from it. This is distinct from the per-tenant
# GITHUB_TOKEN seeded into Vault by 80-seed-tenant-secrets.sh (that one is for the in-cluster
# dag-loader Job, not for Argo CD's own git client) - same token, different consumer.
#
# Onboarding a new tenant: add its repo to the loop below (see docs/runbook-tenant-onboarding.md).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

: "${GITHUB_TOKEN:?set GITHUB_TOKEN to a token with read access to this repo and every tenant repo}"

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

log "registering Argo CD's read credentials for the platform repo and every tenant repo..."
# --server-side (not the default client-side `apply`) is required here: client-side apply embeds
# the full submitted manifest - including this plaintext stringData.password - into the
# kubectl.kubernetes.io/last-applied-configuration annotation, so `kubectl get secret -o yaml`
# (or anything piping through it) would print the raw token. Server-side apply uses managed-fields
# tracking instead and never writes that annotation.
register_repo_creds() {
  local name=$1 url=$2
  kubectl --context "${ctx}" -n argocd apply --server-side -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${name}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${url}
  username: x-access-token
  password: "${GITHUB_TOKEN}"
EOF
}

register_repo_creds platform-repo-creds   "https://github.com/tarekabouzeid/airflow3-infra"
register_repo_creds tenant-a-repo-creds   "https://github.com/tarekabouzeid/airflow3-infra-tenant-a"
register_repo_creds tenant-b-repo-creds   "https://github.com/tarekabouzeid/airflow3-infra-tenant-b"

log "applying the root Application (app-of-apps)..."
kubectl --context "${ctx}" apply -f bootstrap/root-app.yaml

log "Argo CD installed. Fetch the initial admin password with:"
log "  kubectl --context ${ctx} -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
