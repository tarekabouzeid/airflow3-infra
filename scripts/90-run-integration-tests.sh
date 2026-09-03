#!/usr/bin/env bash
# Runs the 2 integration DAGs (KubernetesPodOperator, Spark) for every tenant, each of which
# itself has a local task and a remote-cluster task. Drives Airflow entirely through the
# `airflow` CLI inside the scheduler pod (kubectl exec) rather than the REST API, to sidestep
# Airflow 3's API-server auth setup for what is meant to be a lightweight CI/local smoke test.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

DAG_IDS=(it_kubernetes_pod_operator it_spark)
TENANTS=(tenant-a tenant-b)
declare -A HOME_CLUSTER=( [tenant-a]=af-work-a [tenant-b]=af-work-b )

TIMEOUT_SECS=${INTEGRATION_TEST_TIMEOUT:-600}
overall_rc=0

scheduler_pod() {
  local ctx=$1 ns=$2
  kubectl --context "${ctx}" -n "${ns}" get pods -l component=scheduler -o jsonpath='{.items[0].metadata.name}'
}

run_dag() {
  local tenant=$1 dag_id=$2
  local cluster="${HOME_CLUSTER[$tenant]}"
  local ctx; ctx="$(kctx "${cluster}")"
  local ns="${tenant}-airflow"

  log "[${tenant}] triggering ${dag_id} ..."
  local pod; pod="$(scheduler_pod "${ctx}" "${ns}")"
  [ -n "${pod}" ] || { log "[${tenant}] no scheduler pod found in ${ns}"; return 1; }

  local run_id="it-$(date +%s)"
  kubectl --context "${ctx}" -n "${ns}" exec "${pod}" -- \
    airflow dags trigger "${dag_id}" --run-id "${run_id}" >/dev/null

  local elapsed=0 state="running"
  while (( elapsed < TIMEOUT_SECS )); do
    state=$(kubectl --context "${ctx}" -n "${ns}" exec "${pod}" -- \
      airflow dags state "${dag_id}" "${run_id}" 2>/dev/null | tail -n1 | tr -d '\r')
    case "${state}" in
      success) log "[${tenant}] ${dag_id} (${run_id}) SUCCEEDED"; return 0 ;;
      failed)  log "[${tenant}] ${dag_id} (${run_id}) FAILED"; break ;;
    esac
    sleep 10
    elapsed=$((elapsed + 10))
  done

  warn "[${tenant}] ${dag_id} (${run_id}) did not succeed (last state: ${state}) - dumping task logs"
  kubectl --context "${ctx}" -n "${ns}" exec "${pod}" -- \
    airflow tasks states-for-dag-run "${dag_id}" "${run_id}" || true
  return 1
}

for tenant in "${TENANTS[@]}"; do
  for dag_id in "${DAG_IDS[@]}"; do
    run_dag "${tenant}" "${dag_id}" || overall_rc=1
  done
done

if (( overall_rc == 0 )); then
  log "All integration DAGs succeeded for all tenants."
else
  die "One or more integration DAGs failed - see logs above."
fi
