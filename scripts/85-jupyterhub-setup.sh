#!/usr/bin/env bash
# Sets up the JupyterHub pre-requisites that cannot be committed to git (rule 5):
#
#   1. Builds and pushes the custom hub image (localhost:5001/jupyterhub:<tag>).
#   2. Creates a hub-spawner ServiceAccount in each workload cluster with a ClusterRole
#      that allows creating/deleting the resources the multicluster spawner needs
#      (Namespace, Pod, Service, Ingress, ServiceAccount in per-user namespaces).
#   3. Builds a combined kubeconfig with one context per cluster and stores it as the
#      Secret `jupyterhub-multicluster-kubeconfig` in the `jupyterhub` namespace on
#      af-work-a.  Context names ("af-work-a", "af-work-b") match the profile_list in
#      platform/bootstrap/jupyterhub-af-work-a.yaml.
#   4. Seeds a shared DummyAuthenticator password in Vault and fetches it into the Secret
#      `jupyterhub-auth-env` in the same namespace.
#
# Usage:
#   bash scripts/85-jupyterhub-setup.sh
#   make jupyterhub-setup   # via Makefile wrapper
#
# After this script completes, trigger the Argo CD sync:
#   argocd app sync jupyterhub-af-work-a   (or: make jupyterhub-sync)
#
# The script is idempotent: re-running it rotates the SA tokens and refreshes the Secrets.
# Run it again whenever the tokens need rotation or the hub image is rebuilt.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

# shellcheck disable=SC1091
source versions.env

HUB_TAG="${JUPYTERHUB_HUB_IMAGE_TAG}"
HUB_IMAGE="localhost:5001/jupyterhub:${HUB_TAG}"
SPAWNER_NS="jupyterhub"
SA_NAME="hub-spawner"
TOKEN_SECRET_NAME="${SA_NAME}-token"
mgmt_ctx="$(kctx af-mgmt)"
work_a_ctx="$(kctx af-work-a)"
work_b_ctx="$(kctx af-work-b)"

# ── 1. Build and push the hub image ──────────────────────────────────────────────────────────
log "building hub image ${HUB_IMAGE} ..."
docker build \
  --build-arg "HUB_IMAGE_TAG=${HUB_TAG}" \
  --build-arg "MULTICLUSTER_SPAWNER_VERSION=${MULTICLUSTER_SPAWNER_VERSION}" \
  --build-arg "KUBECTL_VERSION=v1.32.8" \
  -t "${HUB_IMAGE}" \
  images/jupyterhub/

log "pushing ${HUB_IMAGE} to local registry ..."
docker push "${HUB_IMAGE}"

# ── 2. Create hub-spawner SA + RBAC in each cluster ──────────────────────────────────────────
for cluster_ctx in "${work_a_ctx}" "${work_b_ctx}"; do
  cluster="${cluster_ctx#kind-}"   # strip "kind-" prefix to get plain cluster name
  log "provisioning hub-spawner SA on ${cluster} ..."

  kubectl --context "${cluster_ctx}" apply -f - <<YAML
# ClusterRole with the minimal permissions jupyterhub-multicluster-kubespawner needs:
# - Namespace: create (spawner creates jupyter-<username> namespaces)
# - Pod/Service/Ingress/ServiceAccount: full lifecycle inside those namespaces
# - Events: create/patch for status reporting
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hub-spawner
rules:
  - apiGroups: [""]
    resources: [namespaces]
    verbs: [get, list, create, delete]
  - apiGroups: [""]
    resources: [pods, services, serviceaccounts, events, persistentvolumeclaims]
    verbs: [get, list, create, delete, patch, watch]
  - apiGroups: [networking.k8s.io]
    resources: [ingresses]
    verbs: [get, list, create, delete, patch]
  - apiGroups: [""]
    resources: [nodes]
    verbs: [list, get]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: hub-spawner
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: hub-spawner
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
    namespace: kube-system
---
# Long-lived token Secret (kubernetes.io/service-account-token type).
# Kubernetes populates .data.token once the controller processes this Secret.
apiVersion: v1
kind: Secret
metadata:
  name: ${TOKEN_SECRET_NAME}
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
YAML
done

# ── 3. Build combined kubeconfig ──────────────────────────────────────────────────────────────
# Reads the SA token from each cluster and builds a single kubeconfig with one context per
# cluster.  Context names match the profile_list in jupyterhub-af-work-a.yaml.
build_context() {
  local cluster=$1
  local ctx; ctx="$(kctx "${cluster}")"
  local server; server="$(cluster_api_server "${cluster}")"

  log "waiting for ${SA_NAME}-token on ${cluster} ..."
  local token=""
  for _ in $(seq 1 30); do
    token=$(kubectl --context "${ctx}" -n kube-system \
        get secret "${TOKEN_SECRET_NAME}" \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    [ -n "${token}" ] && break
    sleep 2
  done
  [ -n "${token}" ] || die "timed out waiting for ${TOKEN_SECRET_NAME} on ${cluster}"

  local ca
  ca=$(kubectl --context "${ctx}" config view --raw --minify \
       -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  [ -n "${ca}" ] || die "could not read CA from ${cluster}"

  # Emit a single-cluster kubeconfig fragment (context named after the cluster).
  cat <<YAML
# --- context: ${cluster} ---
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
      user: ${SA_NAME}-${cluster}
current-context: ${cluster}
users:
  - name: ${SA_NAME}-${cluster}
    user:
      token: ${token}
YAML
}

log "building hub kubeconfigs ..."
kc_a="$(build_context af-work-a)"
kc_b="$(build_context af-work-b)"

# Merge the two single-cluster kubeconfigs into one file that kubectl can parse.
# kubectl config view --merge reads KUBECONFIG as a colon-separated list and produces a merged
# output — use process substitution + temp files to avoid writing secrets to disk.
merged_kubeconfig=$(
  tmp_a=$(mktemp)
  tmp_b=$(mktemp)
  trap 'rm -f "${tmp_a}" "${tmp_b}"' EXIT
  printf '%s\n' "${kc_a}" >"${tmp_a}"
  printf '%s\n' "${kc_b}" >"${tmp_b}"
  KUBECONFIG="${tmp_a}:${tmp_b}" kubectl config view --raw --merge
)

# ── 4. Write jupyterhub namespace + Secrets on af-work-a ─────────────────────────────────────
log "ensuring namespace ${SPAWNER_NS} exists on af-work-a ..."
kubectl --context "${work_a_ctx}" create namespace "${SPAWNER_NS}" \
  --dry-run=client -o yaml | kubectl --context "${work_a_ctx}" apply -f -

log "writing jupyterhub-multicluster-kubeconfig Secret on af-work-a ..."
kubectl --context "${work_a_ctx}" -n "${SPAWNER_NS}" \
  create secret generic jupyterhub-multicluster-kubeconfig \
  --from-literal="config=${merged_kubeconfig}" \
  --dry-run=client -o yaml \
  | kubectl --context "${work_a_ctx}" apply -f -

# ── 5. Seed Vault + write auth Secret ────────────────────────────────────────────────────────
keys_file="${REPO_ROOT}/.local/vault-keys.json"
if [ -f "${keys_file}" ]; then
  log "seeding jupyterhub shared password in Vault ..."
  ROOT_TOKEN=$(jq -r '.root_token' "${keys_file}")

  # Generate a random shared password if Vault doesn't already have one.
  existing=$(kubectl --context "${mgmt_ctx}" -n vault exec -i vault-0 \
    -- env VAULT_TOKEN="${ROOT_TOKEN}" vault kv get -field=password \
       secret/jupyterhub/auth 2>/dev/null || true)

  if [ -z "${existing}" ]; then
    JPASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
    kubectl --context "${mgmt_ctx}" -n vault exec -i vault-0 -- \
      env VAULT_TOKEN="${ROOT_TOKEN}" \
      vault kv put secret/jupyterhub/auth password="${JPASSWORD}"
    log "generated new shared password (see Vault at secret/jupyterhub/auth)"
  else
    JPASSWORD="${existing}"
    log "using existing shared password from Vault"
  fi
else
  warn "Vault keys not found at .local/vault-keys.json — using a placeholder password."
  warn "Run make vault-init then re-run this script to set a real password."
  JPASSWORD="CHANGE_ME_run_vault_init_first"
fi

log "writing jupyterhub-auth-env Secret on af-work-a ..."
kubectl --context "${work_a_ctx}" -n "${SPAWNER_NS}" \
  create secret generic jupyterhub-auth-env \
  --from-literal="password=${JPASSWORD}" \
  --dry-run=client -o yaml \
  | kubectl --context "${work_a_ctx}" apply -f -

# ── 6. Restart hub pod if already running ────────────────────────────────────────────────────
if kubectl --context "${work_a_ctx}" -n "${SPAWNER_NS}" \
     get deployment hub >/dev/null 2>&1; then
  log "restarting hub Deployment to pick up rotated kubeconfig ..."
  kubectl --context "${work_a_ctx}" -n "${SPAWNER_NS}" rollout restart deployment/hub
fi

log "JupyterHub pre-requisites are ready."
log ""
log "Next: argocd app sync jupyterhub-af-work-a"
log "  (or: make jupyterhub-sync)"
log ""
log "Hub UI will be at: http://localhost:9888"
log "Cluster-A notebooks: http://localhost:9080/user/<username>/"
log "Cluster-B notebooks: http://localhost:9081/user/<username>/"
