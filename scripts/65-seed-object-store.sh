# shellcheck shell=bash
# Gives SeaweedFS (platform/bootstrap/seaweedfs-af-mgmt.yaml, on af-mgmt) its S3 access/secret key
# pair, and wires an `s3_logs` Airflow connection into every tenant's Vault KV mount so
# remote_logging (charts/airflow-tenant) can actually reach it. Needs Vault configured first
# (scripts/60-vault-configure.sh) - this writes into each tenant's KV mount.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

mgmt_ctx="$(kctx af-mgmt)"
keys_file="${REPO_ROOT}/.local/vault-keys.json"
[ -f "${keys_file}" ] || die "run 'make vault-init' first"
ROOT_TOKEN=$(jq -r '.root_token' "${keys_file}")
vexec() { kubectl --context "${mgmt_ctx}" -n vault exec -i vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" "$@"; }

log "ensuring the 'seaweedfs' namespace exists on af-mgmt..."
kubectl --context "${mgmt_ctx}" create namespace seaweedfs --dry-run=client -o yaml \
  | kubectl --context "${mgmt_ctx}" apply -f -

# Generated once, never rotated by re-running this script (idempotent) - same pattern as
# scripts/60-vault-configure.sh's tenant DB password: reuse whatever secret/Vault-connection
# state already exists rather than mint fresh credentials on every run.
if kubectl --context "${mgmt_ctx}" -n seaweedfs get secret seaweedfs-s3-credentials >/dev/null 2>&1; then
  log "seaweedfs-s3-credentials already exists, reusing it..."
  access_key=$(kubectl --context "${mgmt_ctx}" -n seaweedfs get secret seaweedfs-s3-credentials -o jsonpath='{.data.admin_access_key_id}' | base64 -d)
  secret_key=$(kubectl --context "${mgmt_ctx}" -n seaweedfs get secret seaweedfs-s3-credentials -o jsonpath='{.data.admin_secret_access_key}' | base64 -d)
else
  log "generating a new SeaweedFS S3 access/secret key pair..."
  access_key=$(openssl rand -hex 10)
  secret_key=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9')
  kubectl --context "${mgmt_ctx}" -n seaweedfs create secret generic seaweedfs-s3-credentials \
    --from-literal="admin_access_key_id=${access_key}" \
    --from-literal="admin_secret_access_key=${secret_key}"
fi

# NodePort on af-mgmt-control-plane, reachable from af-work-a/af-work-b over the shared `kind`
# Docker network - same addressing scheme as Vault (see scripts/lib/common.sh).
endpoint_url="http://af-mgmt-control-plane:30833"

seed_tenant_connection() {
  local tenant=$1 bucket=$2
  local extra
  extra=$(jq -n --arg ak "${access_key}" --arg sk "${secret_key}" --arg ep "${endpoint_url}" \
    '{aws_access_key_id: $ak, aws_secret_access_key: $sk, endpoint_url: $ep, region_name: "us-east-1"}')

  log "writing ${tenant}/connections/s3_logs to Vault (bucket: ${bucket})..."
  vexec vault kv put "${tenant}/connections/s3_logs" \
    conn_type="aws" \
    extra="${extra}"
}

seed_tenant_connection tenant-a tenant-a-logs
seed_tenant_connection tenant-b tenant-b-logs

log "Object store wired. Airflow's remote_logging can now reach SeaweedFS via the s3_logs connection."
log "NOTE: if the seaweedfs-s3-credentials Secret was just created for the first time, the SeaweedFS"
log "master pod may need a restart to pick it up: kubectl --context ${mgmt_ctx} -n seaweedfs rollout restart deployment/seaweedfs-master"
