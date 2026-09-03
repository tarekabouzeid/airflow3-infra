# shellcheck shell=bash
# Declaratively registers af-work-a and af-work-b as external clusters in Argo CD (running on
# af-mgmt), following Argo CD's own documented cluster-bootstrapping pattern:
# https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

mgmt_ctx="$(kctx af-mgmt)"

register_cluster() {
  local cluster=$1
  local ctx; ctx="$(kctx "${cluster}")"
  local server; server="$(cluster_api_server "${cluster}")"

  log "registering ${cluster} (${server}) with Argo CD..."

  cat <<YAML | kubectl --context "${ctx}" apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-manager-role
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
  - nonResourceURLs: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argocd-manager-role
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
YAML

  log "waiting for argocd-manager token to populate..."
  local token=""
  for _ in $(seq 1 30); do
    token=$(kubectl --context "${ctx}" -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    [ -n "${token}" ] && break
    sleep 2
  done
  [ -n "${token}" ] || die "timed out waiting for argocd-manager token on ${cluster}"

  local ca
  ca=$(kubectl --context "${ctx}" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  [ -n "${ca}" ] || die "could not read CA data for ${cluster}"

  kubectl --context "${mgmt_ctx}" -n argocd apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${cluster}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${cluster}
  server: ${server}
  config: |
    {
      "bearerToken": "${token}",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${ca}"
      }
    }
YAML
  log "${cluster} registered."
}

register_cluster af-work-a
register_cluster af-work-b

log "Registered clusters (from Argo CD's point of view):"
kubectl --context "${mgmt_ctx}" -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
