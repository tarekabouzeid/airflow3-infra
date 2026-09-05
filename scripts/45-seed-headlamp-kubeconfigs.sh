# shellcheck shell=bash
# Gives Headlamp (running on af-mgmt, see platform/bootstrap/headlamp-af-mgmt.yaml) access to
# af-work-a and af-work-b too: mints a long-lived token for a dedicated ServiceAccount on each
# workload cluster (mirroring scripts/40-register-clusters.sh's own argocd-manager pattern), builds
# a standalone kubeconfig per cluster, and stores both in one `headlamp-kubeconfigs` Secret in the
# `headlamp` namespace on af-mgmt - which the Application's Helm values mount and point the
# headlamp-server `-kubeconfig` flag at (config.extraArgs; NOT the KUBECONFIG env var - confirmed
# live that headlamp-server does not read it). af-mgmt itself needs no kubeconfig here: Headlamp's
# `config.inCluster: true` already gives it that cluster via its own pod ServiceAccount/token.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

mgmt_ctx="$(kctx af-mgmt)"

# Prints a standalone kubeconfig for $1 on stdout - callers capture it via command substitution, so
# every other command in here must keep its own stdout out of the way (log() already writes to
# stderr; the one `kubectl apply` below is explicitly redirected).
build_kubeconfig() {
  local cluster=$1
  local ctx; ctx="$(kctx "${cluster}")"
  local server; server="$(cluster_api_server "${cluster}")"
  local sa="headlamp-manager"

  log "minting ${sa} token on ${cluster}..."
  kubectl --context "${ctx}" apply -f - 1>&2 <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${sa}
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${sa}-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: ${sa}
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: ${sa}-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: ${sa}
type: kubernetes.io/service-account-token
YAML

  local token=""
  for _ in $(seq 1 30); do
    token=$(kubectl --context "${ctx}" -n kube-system get secret "${sa}-token" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    [ -n "${token}" ] && break
    sleep 2
  done
  [ -n "${token}" ] || die "timed out waiting for ${sa}-token on ${cluster}"

  local ca
  ca=$(kubectl --context "${ctx}" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  [ -n "${ca}" ] || die "could not read CA data for ${cluster}"

  cat <<YAML
apiVersion: v1
kind: Config
clusters:
  - name: ${cluster}
    cluster:
      server: ${server}
      certificate-authority-data: ${ca}
contexts:
  - name: ${cluster}
    context:
      cluster: ${cluster}
      user: ${sa}
current-context: ${cluster}
users:
  - name: ${sa}
    user:
      token: ${token}
YAML
}

log "building kubeconfigs for af-work-a and af-work-b..."
kubeconfig_a="$(build_kubeconfig af-work-a)"
kubeconfig_b="$(build_kubeconfig af-work-b)"

log "ensuring the 'headlamp' namespace exists on af-mgmt..."
kubectl --context "${mgmt_ctx}" create namespace headlamp --dry-run=client -o yaml \
  | kubectl --context "${mgmt_ctx}" apply -f -

log "writing headlamp-kubeconfigs Secret on af-mgmt..."
kubectl --context "${mgmt_ctx}" -n headlamp create secret generic headlamp-kubeconfigs \
  --from-literal="af-work-a=${kubeconfig_a}" \
  --from-literal="af-work-b=${kubeconfig_b}" \
  --dry-run=client -o yaml \
  | kubectl --context "${mgmt_ctx}" apply -f -

if kubectl --context "${mgmt_ctx}" -n headlamp get deployment headlamp >/dev/null 2>&1; then
  log "restarting the headlamp Deployment so it picks up the new kubeconfigs..."
  kubectl --context "${mgmt_ctx}" -n headlamp rollout restart deployment/headlamp
else
  log "headlamp Deployment not up yet on af-mgmt - it will pick up this Secret on first start."
fi

log "af-work-a and af-work-b are now accessible from Headlamp (af-mgmt is via config.inCluster)."
