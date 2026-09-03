#!/usr/bin/env bash
# Idempotent Vault configuration: one Kubernetes auth mount PER CLUSTER (auth validates a SA
# token against exactly one cluster's TokenReview API), one KV-v2 mount per tenant, and per-tenant
# policies/roles binding specific ServiceAccounts to least-privilege paths.
#
# Only 2 auth mounts exist (kubernetes-work-a, kubernetes-work-b): nothing running on af-mgmt
# itself (where Vault lives) currently needs to authenticate back into Vault via Kubernetes auth,
# so a third "kubernetes-mgmt" mount would be unused - left out rather than added speculatively.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

mgmt_ctx="$(kctx af-mgmt)"
keys_file="${REPO_ROOT}/.local/vault-keys.json"
[ -f "${keys_file}" ] || die "run 'make vault-init' first"
ROOT_TOKEN=$(jq -r '.root_token' "${keys_file}")

vexec() { kubectl --context "${mgmt_ctx}" -n vault exec -i vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" "$@"; }

ensure_kv_mount() {
  local mount=$1
  if vexec vault secrets list -format=json | jq -e --arg m "${mount}/" 'has($m)' >/dev/null 2>&1; then
    log "KV mount ${mount} already exists"
  else
    log "enabling KV-v2 mount ${mount}"
    vexec vault secrets enable -path="${mount}" -version=2 kv
  fi
}

# Sets up the Kubernetes auth mount for one cluster: creates a dedicated token-reviewer
# ServiceAccount there (bound to system:auth-delegator) and points Vault at that cluster's API.
ensure_k8s_auth_mount() {
  local cluster=$1 mount=$2
  local ctx; ctx="$(kctx "${cluster}")"

  vexec vault auth list -format=json | jq -e --arg m "${mount}/" 'has($m)' >/dev/null 2>&1 \
    && { log "auth mount ${mount} already exists"; return 0; }

  log "creating vault-token-reviewer SA on ${cluster}..."
  kubectl --context "${ctx}" apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-token-reviewer
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-token-reviewer-auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: vault-token-reviewer
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: vault-token-reviewer-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: vault-token-reviewer
type: kubernetes.io/service-account-token
YAML

  local jwt=""
  for _ in $(seq 1 30); do
    jwt=$(kubectl --context "${ctx}" -n kube-system get secret vault-token-reviewer-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    [ -n "${jwt}" ] && break
    sleep 2
  done
  [ -n "${jwt}" ] || die "timed out waiting for vault-token-reviewer token on ${cluster}"

  local ca; ca=$(kubectl --context "${ctx}" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)
  local host; host=$(cluster_api_server "${cluster}")

  log "enabling kubernetes auth mount ${mount} for ${cluster}..."
  vexec vault auth enable -path="${mount}" kubernetes
  vexec vault write "auth/${mount}/config" \
    kubernetes_host="${host}" \
    kubernetes_ca_cert="${ca}" \
    token_reviewer_jwt="${jwt}"
}

ensure_tenant_role() {
  local mount=$1 role=$2 sa=$3 ns=$4 policy=$5
  log "writing role ${role} on ${mount} (sa=${sa} ns=${ns})..."
  vexec vault write "auth/${mount}/role/${role}" \
    bound_service_account_names="${sa}" \
    bound_service_account_namespaces="${ns}" \
    policies="${policy}" \
    ttl=1h
}

ensure_policy() {
  local name=$1 hcl=$2
  echo "${hcl}" | vexec vault policy write "${name}" -
}

configure_tenant() {
  local tenant=$1 home=$2 home_mount=$3 remote=$4 remote_mount=$5

  log "configuring tenant ${tenant}: home=${home} (${home_mount}), remote=${remote} (${remote_mount})"
  ensure_kv_mount "${tenant}"

  ensure_policy "${tenant}-airflow" "
path \"${tenant}/data/connections/*\" { capabilities = [\"read\", \"list\"] }
path \"${tenant}/data/variables/*\"   { capabilities = [\"read\", \"list\"] }
"
  ensure_policy "${tenant}-eso" "
path \"${tenant}/data/db\"               { capabilities = [\"read\"] }
path \"${tenant}/data/git\"              { capabilities = [\"read\"] }
path \"${tenant}/data/workload-secrets\" { capabilities = [\"read\"] }
"

  # Airflow's own VaultBackend identity - home cluster only.
  ensure_tenant_role "${home_mount}" "${tenant}-airflow" "${tenant}-airflow" "${tenant}-airflow" "${tenant}-airflow"

  # ESO identity - bound for BOTH ServiceAccounts that exist on the home cluster (the Airflow SA,
  # for the postgres/git ExternalSecrets in the airflow namespace, and the workload-runner SA, for
  # the local workloads namespace), and for just the workload-runner SA on the remote cluster.
  ensure_tenant_role "${home_mount}" "${tenant}-eso" "${tenant}-airflow,${tenant}-workload-runner" "${tenant}-airflow,${tenant}-workloads" "${tenant}-eso"
  ensure_tenant_role "${remote_mount}" "${tenant}-eso" "${tenant}-workload-runner" "${tenant}-workloads" "${tenant}-eso"

  # Internal DB credential - generated once, never in git. Re-running this script does not
  # rotate it (idempotent): only writes if the path doesn't exist yet.
  if ! vexec vault kv get "${tenant}/db" >/dev/null 2>&1; then
    log "seeding ${tenant}/db with a generated password..."
    local pass; pass=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')
    vexec vault kv put "${tenant}/db" user="${tenant//-/_}" password="${pass}" dbname="${tenant//-/_}"
  else
    log "${tenant}/db already seeded"
  fi
}

ensure_k8s_auth_mount af-work-a kubernetes-work-a
ensure_k8s_auth_mount af-work-b kubernetes-work-b

# tenant-a: home=af-work-a, remote=af-work-b (see platform/tenants/tenant-a/*.yaml)
configure_tenant tenant-a af-work-a kubernetes-work-a af-work-b kubernetes-work-b
# tenant-b: home=af-work-b, remote=af-work-a (see platform/tenants/tenant-b/*.yaml)
configure_tenant tenant-b af-work-b kubernetes-work-b af-work-a kubernetes-work-a

log "Vault configuration complete."
log "NOTE: run 'make seed-tenant-secrets' next to add the GitHub deploy token + example DAG connections/variables."
