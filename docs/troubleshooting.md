# Troubleshooting

**A tenant Application is stuck `Progressing` or `Degraded` right after bootstrap.**
Expected until `make vault-configure` (and `make seed-tenant-secrets`) have run: the tenant's
`SecretStore` can't authenticate to Vault yet, so its `ExternalSecret`s never become Ready, so the
Postgres/Airflow pods that depend on those Secrets never start. `selfHeal: true` means once Vault
is configured, everything catches up on its own within a few minutes - no manual resync needed.

**`vault status` says sealed after a cluster restart.**
Vault does not auto-unseal (this is deliberate - see `docs/architecture.md`). Run
`make vault-init` again; it detects Vault is already initialized and only performs the unseal
step, using the key in `.local/vault-keys.json`. If that file is missing, Vault is unrecoverable -
delete the `vault` PVC and re-run `make vault-init` from scratch (you will lose all secrets and
need to re-run `make vault-configure` and `make seed-tenant-secrets` too).

**Cross-cluster addresses like `af-work-b-control-plane:6443` don't resolve from a pod.**
Confirm all 3 clusters' control-plane containers are actually on the shared `kind` Docker
network: `docker network inspect kind --format '{{range .Containers}}{{.Name}} {{end}}'`. If one
is missing, it was likely created before the `kind` network existed, or with a different
`--network` override - recreate that cluster.

**A dag-loader Job fails with a git auth error.**
`GITHUB_TOKEN` wasn't seeded (`make seed-tenant-secrets`), the token expired, or it lacks read
access to the tenant repo. Check `<tenant>/git` in Vault
(`kubectl -n vault exec -i vault-0 -- vault kv get <tenant>/git`) and the ExternalSecret status
(`kubectl -n <tenant>-airflow get externalsecret <tenant>-git-token -o yaml`).

**`airflow dags list-import-errors` shows an error for a KubernetesPodOperator/
SparkKubernetesOperator DAG.**
Almost always a provider-version API mismatch, not a logic bug - both operators' constructor
arguments have changed across `apache-airflow-providers-cncf-kubernetes` releases, and this repo
was built without the ability to run the real provider locally to verify exact argument names
(see `docs/IMPLEMENTATION_PLAN.md`'s Rule 0). Check the installed provider version
(`airflow providers list`) against
`https://airflow.apache.org/docs/apache-airflow-providers-cncf-kubernetes/stable/_api/airflow/providers/cncf/kubernetes/operators/`
and adjust the DAG.

**A `KubernetesPodOperator`/`SparkKubernetesOperator` task with `kubernetes_conn_id="k8s_remote"`
fails to authenticate.**
Re-run `make remote-access` - the token minted for `<tenant>-workload-runner` is long-lived but
not eternal, and re-running is idempotent (it overwrites the Vault connection with a fresh
token). If the workload-runner ServiceAccount itself is missing, its owning Application
(`<tenant>-workloads-<cluster>`) hasn't synced yet on that cluster.

**The `vault` Application's StatefulSet stays permanently `OutOfSync`, even though Vault is
clearly up and every other resource in the Application shows `Synced`.**
Confirmed root cause (via `helm template` vs. the live object - see
`platform/bootstrap/vault-af-mgmt.yaml`): the API server back-fills `apiVersion`, `kind`, `status`,
and `spec.volumeMode` onto each StatefulSet `volumeClaimTemplates` entry, none of which the Vault
chart's manifest ever sets, so Argo CD's diffing sees a permanent cosmetic diff on that one field.
Fixed with a targeted `ignoreDifferences` entry on the `vault` Application (confirmed via the
`helm template` diff first, not guessed). Left unfixed, this isn't just cosmetic in a real local
run: the continuous selfHeal resync it triggers (and propagates up to `root`, which watches every
child Application) can starve the application-controller's attention on other Applications enough
to visibly stall their own sync progress - if a tenant Application's sync looks permanently stuck
on `Running` for no clear reason, check `kubectl -n argocd logs statefulset/argocd-application-
controller` for `vault`/`root` churn crowding it out before assuming the tenant Application itself
is broken.

**Argo CD Application flips to `Unknown` health mid Argo-CD-upgrade.**
Expected - see `docs/runbook-argocd-upgrade.md`. The application-controller restarts itself
during its own upgrade. Give it a few minutes before treating it as a real failure.

**The `root` Application sits `Unknown` sync status right after `make bootstrap`, with condition
`Failed to load target state: ... authentication required. Repository not found.`**
Confirmed root cause: `platform/bootstrap/*.yaml` and `bootstrap/root-app.yaml` point at this
platform repo itself over HTTPS (`https://github.com/tarekabouzeid/airflow3-infra`), which is
private - Argo CD has no credential for it out of the box. This is separate from the per-tenant
`GITHUB_TOKEN` seeded into Vault by `make seed-tenant-secrets` (that one is for the in-cluster
dag-loader Job, not Argo CD's own git client). Fixed in `scripts/30-install-argocd.sh`: it now
requires `GITHUB_TOKEN` and registers a `platform-repo-creds` Secret
(`argocd.argoproj.io/secret-type: repository`) in the `argocd` namespace before applying the root
Application - run `GITHUB_TOKEN=ghp_xxx make bootstrap` (or `make install-argocd`), not bare
`make bootstrap`. This was never caught before because CI's `e2e-kind.yaml` deliberately never
exercises the platform's own Argo CD Application layer (see the comment at the top of that
workflow) - only a real local `make bootstrap` run reaches this code path.

**A `<tenant>-airflow` Application shows `ComparisonError`:
`failed to get git client for repo https://github.com/tarekabouzeid/airflow3-infra-tenant-<x>`.**
Same class of issue as the platform-repo credential above, one level down: this Application's
source 3 of 3 pulls `deploy/airflow/values.yaml` straight from the tenant's own (private) repo,
and Argo CD needs its own read credential for that repo too - separate from the per-tenant
`GITHUB_TOKEN` seeded into Vault (that one's for the in-cluster dag-loader Job). Fixed in
`scripts/30-install-argocd.sh`, which now registers a `<tenant>-repo-creds` Secret for each tenant
alongside the platform one; re-run `GITHUB_TOKEN=ghp_xxx make install-argocd`.

**The `root` Application (or anything under it) fails with a revision/branch-not-found error even
after Argo CD has a working repo credential.**
Every platform bootstrap manifest hardcodes `targetRevision: main` for this repo. If you're
working on a branch that was never merged/pushed to `main`, that branch is what Argo CD needs to
see - `main` not existing (or being stale) will surface as this error. Confirm with
`git ls-remote origin main`; if missing, push your working branch there
(`git push origin <branch>:main`) after confirming with whoever owns the repo, since it's a
shared, visible change.

**GitHub Actions `e2e-kind.yaml` fails on a `kubectl rollout status deployment/tenant-ci-airflow-*`
step with "not found".**
The official `apache-airflow/airflow` chart's exact resource-naming convention was not verified
against a live render before this workflow was written (no local Helm/registry access - see
`docs/IMPLEMENTATION_PLAN.md`'s Rule 0). Check the actual generated names with
`kubectl -n tenant-ci-airflow get deployments` in the failed run's logs and fix the step name,
rather than assuming the DAG/chart logic itself is wrong.
