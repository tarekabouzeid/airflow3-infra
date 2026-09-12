#!/usr/bin/env bash
# Forwards Argo CD UI (8080), Headlamp (8083), Vault UI (8200), SeaweedFS filer (8888), and both
# tenants' Airflow UIs (8081/8082) to localhost, in the background, detached from this script's own
# shell so they keep running after it exits (WSL2 and most local setups auto-forward listening
# localhost ports to the host, so this also works through a VM/container boundary without extra
# config).
#
# Safe to re-run: always stops any port-forwards this script previously started before launching
# fresh ones - idempotent, and doubles as `bash scripts/95-port-forward.sh stop`.
#
# Standalone usage (bootstrap already done, cluster still running):
#   bash scripts/95-port-forward.sh
# Called automatically at the end of `make bootstrap` for immediate Argo CD access. Tenant
# Airflow UIs aren't up that early - this script skips whichever aren't ready yet with a message,
# rather than failing. Re-run it (or `make port-forward`) once `make test-integration` is green
# to pick those up too.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

pid_file="${REPO_ROOT}/.local/port-forward.pids"

stop_existing() {
  if [ -f "${pid_file}" ]; then
    while read -r pid; do
      # if/fi rather than `[ -n x ] && kill || true`: shellcheck SC2015 flags that form because
      # A && B || C is not if-then-else - C also runs when A succeeds and B fails, so the `|| true`
      # was silently swallowing a genuine kill failure as well as the empty-pid case it was for.
      if [ -n "${pid}" ]; then
        kill "${pid}" 2>/dev/null || true
      fi
    done < "${pid_file}"
    rm -f "${pid_file}"
  fi
}

start_forward() {
  local name=$1 ctx=$2 ns=$3 svc=$4 local_port=$5 remote_port=$6
  if ! kubectl --context "${ctx}" -n "${ns}" get svc "${svc}" >/dev/null 2>&1; then
    warn "${name}: svc/${svc} not found in ${ns} on ${ctx} yet - skipping (re-run this script once it's up)"
    return
  fi
  nohup kubectl --context "${ctx}" -n "${ns}" port-forward --address 0.0.0.0 "svc/${svc}" "${local_port}:${remote_port}" \
    > "${REPO_ROOT}/.local/port-forward-${name}.log" 2>&1 &
  local pid=$!
  disown "${pid}" 2>/dev/null || true
  echo "${pid}" >> "${pid_file}"
  log "${name}: http://localhost:${local_port} (pid ${pid}, log: .local/port-forward-${name}.log)"
}

stop_existing

if [ "${1:-}" = "stop" ]; then
  log "Stopped."
  exit 0
fi

mgmt_ctx="$(kctx af-mgmt)"
a_ctx="$(kctx af-work-a)"
b_ctx="$(kctx af-work-b)"

start_forward argocd    "${mgmt_ctx}" argocd           argocd-server               8080 443
start_forward headlamp  "${mgmt_ctx}" headlamp         headlamp                    8083 80
start_forward vault     "${mgmt_ctx}" vault            vault-ui                    8200 8200
start_forward seaweedfs "${mgmt_ctx}" seaweedfs        seaweedfs-filer             8888 8888
start_forward tenant-a  "${a_ctx}"    tenant-a-airflow tenant-a-airflow-api-server 8081 8080
start_forward tenant-b  "${b_ctx}"    tenant-b-airflow tenant-b-airflow-api-server 8082 8080

log "Argo CD login: admin / \$(kubectl --context ${mgmt_ctx} -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
log "Headlamp login: token from a ServiceAccount in the headlamp namespace, e.g. \`kubectl --context ${mgmt_ctx} -n headlamp create token \$(kubectl --context ${mgmt_ctx} -n headlamp get sa -o jsonpath='{.items[0].metadata.name}')\`"
log "Vault login: Token method, root token from \`jq -r '.root_token' ${REPO_ROOT}/.local/vault-keys.json\`"
log "SeaweedFS filer: no auth in this lab - browse buckets/objects directly"
log "Tenant Airflow login: admin / admin (chart default)"
log "Stop all: bash scripts/95-port-forward.sh stop"
