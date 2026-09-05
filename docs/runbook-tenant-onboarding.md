# Runbook: onboard a new tenant

Tenants never touch anything under `platform/` - onboarding is entirely the platform operator's
action, in the platform repo, and it is deliberately small.

## 1. Create the tenant's GitHub repo

Same shape as `airflow3-infra-tenant-a`/`-b`:
```
CLAUDE.md                        # tenant-scoped Claude Code context - keep this, don't skip it
deploy/airflow/values.yaml      # image tag + resource overrides only
deploy/workloads/                # Helm chart: SecretStore + ExternalSecret for workload secrets
dags/
  it_kubernetes_pod_operator.py
  it_spark.py
  spark/spark_pi.yaml
tests/test_dags_import.py
.github/workflows/{lint.yaml,dag-validate.yaml}
```
Easiest path: copy an existing tenant repo and rename every `tenant-a`/`tenant-b` occurrence to
the new tenant name (`grep -rl tenant-a . | xargs sed -i 's/tenant-a/tenant-c/g'`) - this also
updates the copied `CLAUDE.md`'s tenant name, home/remote cluster, and Vault mount point/role
references, so double check it reads correctly for the new tenant rather than assuming the sed
caught everything.

## 2. Add the tenant registry entry (platform repo)

```
platform/tenants/<tenant>/
  tenant.yaml                    # picks up an AppProject + an Airflow Application
  workloads-<home-cluster>.yaml  # local workloads namespace
  workloads-<remote-cluster>.yaml (repeat per additional cluster the tenant targets)
```

Copy `platform/tenants/tenant-a/*.yaml` and adjust: `tenant`, `tenantRepoURL`, `homeCluster`,
`vault.mountPoint`/`airflowRole`/`esoRole` (by convention, same as `tenant` name), and each
`workloads-*.yaml`'s `cluster` block + `isLocal` + (for the local one only)
`localAirflowServiceAccountNamespace`/`Name`.

Commit and push. The 3 ApplicationSets (`appset-tenant-projects`, `appset-tenant-airflow`,
`appset-tenant-workloads`) pick the new files up on their next git-generator refresh (a few
minutes, or force it: `kubectl -n argocd annotate applicationset tenant-airflow
argocd.argoproj.io/refresh=hard --overwrite`).

## 3. Add the tenant to Spark Operator's watched namespaces

`platform/bootstrap/spark-operator-af-work-a.yaml` and `-af-work-b.yaml` list
`spark.jobNamespaces` explicitly (a small, deliberate coupling - see `docs/architecture.md`).
Add `<tenant>-workloads` to both files, commit, push.

## 4. Register the new tenant repo with Argo CD

Argo CD needs its own read credential for the tenant's repo (separate from the `GITHUB_TOKEN`
seeded into Vault in the next step, which is for the in-cluster dag-loader Job, not Argo CD's git
client) - `appset-tenant-airflow.yaml`'s source 3 of 3 pulls `deploy/airflow/values.yaml` straight
from it. Add a `register_repo_creds` call for the new tenant in `scripts/30-install-argocd.sh`,
then re-run:
```bash
GITHUB_TOKEN=ghp_xxx make install-argocd
```

## 5. Configure Vault for the new tenant

Extend `scripts/60-vault-configure.sh`'s two `configure_tenant` calls with a third, matching the
new tenant's home/remote clusters, then re-run:
```bash
make vault-configure
GITHUB_TOKEN=ghp_xxx make seed-tenant-secrets   # extend the tenant loop there too
make remote-access                               # extend wire_remote_access there too
```

## 6. Verify

```bash
make status              # <tenant>-project, <tenant>-airflow, <tenant>-workloads-* all Healthy
make test-integration    # extend TENANTS/HOME_CLUSTER in scripts/90-run-integration-tests.sh first
```

Total new/changed files for a tenant with one remote cluster: 2 files in the platform repo
(`tenant.yaml` + one `workloads-*.yaml` per additional cluster beyond the home one), one small
edit to each Spark Operator Application, one small edit to `scripts/30-install-argocd.sh`, and one
small edit to `scripts/60-vault-configure.sh` - plus the new tenant's own repo. Nothing in
`charts/` changes.
