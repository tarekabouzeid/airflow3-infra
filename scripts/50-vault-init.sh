#!/usr/bin/env bash
# Vault runs standalone with file storage (not dev mode) - init/unseal is a real, repeatable
# exercise. Single key share/threshold is a deliberate LAB simplification (production would use
# Shamir with multiple holders, or auto-unseal via a cloud KMS).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

ctx="$(kctx af-mgmt)"
keys_file="${REPO_ROOT}/.local/vault-keys.json"

wait_for_pod() {
  for _ in $(seq 1 60); do
    kubectl --context "${ctx}" -n vault get pod vault-0 >/dev/null 2>&1 && return 0
    sleep 5
  done
  die "vault-0 pod never appeared - is the Argo CD Application 'vault' Synced?"
}

vexec() { kubectl --context "${ctx}" -n vault exec -i vault-0 -- "$@"; }

wait_for_pod

status_json=$(vexec vault status -format=json 2>/dev/null || true)
initialized=$(echo "${status_json}" | jq -r '.initialized // false')

if [ "${initialized}" != "true" ]; then
  log "initializing Vault (1 key share / threshold 1 - lab only)..."
  init_json=$(vexec vault operator init -key-shares=1 -key-threshold=1 -format=json)
  echo "${init_json}" > "${keys_file}"
  chmod 600 "${keys_file}"
  log "unseal key + root token written to ${keys_file} (gitignored - never commit this)"
else
  log "Vault already initialized."
  [ -f "${keys_file}" ] || die "Vault is initialized but ${keys_file} is missing - cannot unseal. See docs/troubleshooting.md."
fi

sealed=$(vexec vault status -format=json | jq -r '.sealed')
if [ "${sealed}" == "true" ]; then
  log "unsealing Vault..."
  key=$(jq -r '.unseal_keys_b64[0]' "${keys_file}")
  vexec vault operator unseal "${key}" >/dev/null
else
  log "Vault already unsealed."
fi

log "Vault status:"
vexec vault status
