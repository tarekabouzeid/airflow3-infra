#!/usr/bin/env bash
# Gives each tenant's Airflow a way to reach ITS remote workload cluster: mints a long-lived
# token for the workload-runner ServiceAccount that charts/tenant-project already created there
# (via GitOps), builds a kubeconfig, and stores it in Vault as a Kubernetes connection
# ("k8s_remote") that Airflow's VaultBackend serves straight to KubernetesPodOperator /
# SparkKubernetesOperator via kubernetes_conn_id="k8s_remote".
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

mgmt_ctx="$(kctx af-mgmt)"
keys_file="${REPO_ROOT}/.local/vault-keys.json"
[ -f "${keys_file}" ] || die "run 'make vault-init' first"
ROOT_TOKEN=$(jq -r '.root_token' "${keys_file}")
vexec() { kubectl --context "${mgmt_ctx}" -n vault exec -i vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" "$@"; }

wire_remote_access() {
  local tenant=$1 remote_cluster=$2
  local ctx; ctx="$(kctx "${remote_cluster}")"
  local ns="${tenant}-workloads"
  local sa="${tenant}-workload-runner"

  log "wiring ${tenant} -> remote cluster ${remote_cluster} (namespace ${ns})..."

  for _ in $(seq 1 30); do
    kubectl --context "${ctx}" -n "${ns}" get serviceaccount "${sa}" >/dev/null 2>&1 && break
    sleep 5
  done
  kubectl --context "${ctx}" -n "${ns}" get serviceaccount "${sa}" >/dev/null 2>&1 \
    || die "${sa} not found in ${ns} on ${remote_cluster} - has the tenant-workloads Application synced?"

  local token_secret="${sa}-long-lived-token"
  kubectl --context "${ctx}" -n "${ns}" apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${token_secret}
  namespace: ${ns}
  annotations:
    kubernetes.io/service-account.name: ${sa}
type: kubernetes.io/service-account-token
YAML

  local token=""
  for _ in $(seq 1 30); do
    token=$(kubectl --context "${ctx}" -n "${ns}" get secret "${token_secret}" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    [ -n "${token}" ] && break
    sleep 2
  done
  [ -n "${token}" ] || die "timed out waiting for ${token_secret} on ${remote_cluster}"

  local ca; ca=$(kubectl --context "${ctx}" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  local server; server=$(cluster_api_server "${remote_cluster}")

  local kubeconfig
  kubeconfig=$(cat <<YAML
apiVersion: v1
kind: Config
clusters:
  - name: ${remote_cluster}
    cluster:
      server: ${server}
      certificate-authority-data: ${ca}
contexts:
  - name: ${remote_cluster}
    context:
      cluster: ${remote_cluster}
      namespace: ${ns}
      user: ${sa}
current-context: ${remote_cluster}
users:
  - name: ${sa}
    user:
      token: ${token}
YAML
)

  local extra
  extra=$(jq -n --arg kc "${kubeconfig}" '{kube_config: $kc, in_cluster: false}')

  log "writing ${tenant}/connections/k8s_remote to Vault..."
  vexec vault kv put "${tenant}/connections/k8s_remote" \
    conn_type="kubernetes" \
    extra="${extra}"
}

# tenant-a's home is af-work-a, so its remote is af-work-b - and vice versa for tenant-b.
wire_remote_access tenant-a af-work-b
wire_remote_access tenant-b af-work-a

log "Remote access wired. Verify with: airflow connections get k8s_remote (from a pod in the tenant's Airflow namespace)."
