#!/usr/bin/env bash
# Seeds the secrets a human has to provide (never generated, never guessed):
#   - a GitHub token the dag-loader Job uses to clone each (private) tenant repo
#   - a demo "workload secret" the integration test DAGs read back via ESO, proving the full
#     Vault -> ESO -> pod path end to end in both local and remote clusters
#
# Usage: GITHUB_TOKEN=ghp_xxx bash scripts/80-seed-tenant-secrets.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

: "${GITHUB_TOKEN:?set GITHUB_TOKEN to a token with read access to the tenant repos}"

mgmt_ctx="$(kctx af-mgmt)"
keys_file="${REPO_ROOT}/.local/vault-keys.json"
[ -f "${keys_file}" ] || die "run 'make vault-init' first"
ROOT_TOKEN=$(jq -r '.root_token' "${keys_file}")
vexec() { kubectl --context "${mgmt_ctx}" -n vault exec -i vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" "$@"; }

for tenant in tenant-a tenant-b; do
  log "seeding ${tenant}/git..."
  vexec vault kv put "${tenant}/git" token="${GITHUB_TOKEN}"

  log "seeding ${tenant}/workload-secrets (demo value for the integration test DAGs)..."
  vexec vault kv put "${tenant}/workload-secrets" \
    greeting="hello from Vault via ESO, ${tenant}"

  log "seeding an example Airflow Variable for ${tenant} (proves the VaultBackend end to end)..."
  vexec vault kv put "${tenant}/variables/hello" value="hello from Vault, ${tenant}"
done

log "Tenant secrets seeded."
