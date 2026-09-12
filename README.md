# airflow3-infra

A reproducible, infrastructure-as-code lab for a **multi-tenant Apache Airflow 3 platform on
Kubernetes, managed by a central Argo CD**, running entirely on local KIND clusters.

## What this builds

- **Central Argo CD** (self-managed via GitOps) deploying Airflow to multiple clusters.
- **Per-tenant configuration in separate GitHub repos**
  (`airflow3-infra-tenant-a`, `airflow3-infra-tenant-b`), with the trust boundary enforced by an
  Argo CD `AppProject` per tenant.
- **3 KIND clusters**: `af-mgmt` (Argo CD + Vault), `af-work-a` (Airflow + workloads),
  `af-work-b` (remote workload target).
- **Remote workload execution** — each tenant runs `KubernetesPodOperator` and Spark jobs both in
  its home cluster and in a remote cluster.
- **OSS HashiCorp Vault** as the secret source: Airflow Connections/Variables come from Vault
  directly via the Airflow Vault secrets backend; workload-pod secrets are delivered by the
  **External Secrets Operator** in every cluster.
- **Spark via the Kubeflow Spark Operator**, plus generic pods via `KubernetesPodOperator`.
- **DAGs on a PVC**, populated by a loader Job that clones the tenant repo.
- **Two lightweight integration tests per tenant** (one Spark, one KubernetesPodOperator), each
  exercised locally and remotely.
- **Multi-tenant governance at admission time**: Kueue gives every tenant a guaranteed-quota
  queue lane and an opportunistic one with cluster-wide gang scheduling; Kyverno bounds what a
  tenant pod may do (image registry, resource ceilings, PriorityClass, Pod Security, node
  pinning). Platform-owned, GitOps-deployed, tenants pick a lane and nothing else. See
  [`docs/runbook-governance.md`](docs/runbook-governance.md).
- **Shared JupyterHub with cross-cluster notebook spawning**: one hub in af-work-a serves both
  tenants; users choose "Cluster A" or "Cluster B" and the notebook pod spawns there via
  `jupyterhub-multicluster-kubespawner`. Hub at `http://localhost:9888`, notebooks at
  `:9080` (A) / `:9081` (B). See [`docs/runbook-jupyterhub.md`](docs/runbook-jupyterhub.md).
- **CI in GitHub Actions**: lint, policy checks, rendered-manifest diffs on PRs, a reduced
  single-cluster KIND smoke test, a dedicated real-cluster governance smoke test, and a nightly
  Argo CD upgrade rehearsal.

## Execution model: KubernetesExecutor, not Celery

Each tenant's Airflow runs with the **KubernetesExecutor** — there is no Celery, no persistent
worker pool, no message broker. Every task the scheduler dispatches becomes a fresh pod, created
directly via the Kubernetes API, on the tenant's **home** cluster.

"Remote" execution is not the executor reaching across clusters — it's the *task* doing so. The
home-cluster task pod running `KubernetesPodOperator` or `SparkKubernetesOperator` is handed a
second Kubernetes connection (`kubernetes_conn_id="k8s_remote"`) that points at the *other*
cluster's API server, so one operator call creates a pod/`SparkApplication` over there instead of
locally. That connection is a kubeconfig built around a long-lived token for a
`<tenant>-workload-runner` ServiceAccount that GitOps already provisioned in the remote cluster's
`<tenant>-workloads` namespace (`scripts/70-remote-access.sh`); it's stored in Vault and pulled in
at task-run time by the same Vault secrets backend used for every other Airflow connection.
tenant-a and tenant-b are deliberately mirrored (home `af-work-a`/remote `af-work-b` and vice
versa) so both clusters get exercised as both "home" and "remote". Full detail:
[`docs/architecture.md`](docs/architecture.md#remote-workload-execution).

## Status

Bootstrapped and run end to end on a real local 3-cluster lab (not just CI).

| Component | Status |
|---|---|
| Argo CD, Vault, ESO, Spark Operator | Healthy, both clusters |
| Tenant A / B Airflow (api-server, scheduler, dag-processor, triggerer, postgres) | Healthy, both clusters |
| `it_kubernetes_pod_operator` (local + cross-cluster) | Passing, both tenants |
| `it_spark` (local + cross-cluster) | Bugs fixed, each fix verified directly; `make test-integration` can still be disrupted - see below |
| Kueue + Kyverno governance | Verified on a real KIND cluster (`.github/workflows/governance-kind.yaml`): registry/priority rejections, quota-gated admission, queue-lane-driven priority all confirmed against a live API server. Ships `policy.action: Audit`; see `make governance-enforce` before flipping to `Enforce`. |
| JupyterHub (cross-cluster) | Hub + ingress-nginx Applications committed; setup script and Makefile targets in place. Requires `make jupyterhub-setup` + `make jupyterhub-sync` after the clusters are up (not auto-synced — see `docs/runbook-jupyterhub.md`). |

**Open issue:** `tenant-a-airflow`/`tenant-b-airflow` sit persistently `OutOfSync` with
`selfHeal: true`, so Argo CD periodically re-syncs them, regenerating hook-created Secrets and
occasionally invalidating an in-flight task. Root cause not yet isolated - see
[`docs/troubleshooting.md`](docs/troubleshooting.md).

See [`docs/architecture.md`](docs/architecture.md) for the as-built design and every place it
deviates from the original plan, and
[`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) for the original approved design.

## Versions

| Component | Version |
|---|---|
| Argo CD | 7.8.28 chart / v2.14.11 |
| HashiCorp Vault | 0.30.0 chart / 1.19.0 |
| Headlamp | 0.45.0 chart / 0.45.0 |
| SeaweedFS | 4.45.0 chart / 4.45 |
| External Secrets Operator | 0.10.4 |
| Kubeflow Spark Operator | 2.5.2 |
| Apache Airflow | 1.22.0 chart / 3.1.7 |
| Spark (jobs) | 4.0.4 |
| Postgres (metadata DB) | 16-alpine |
| KIND node image | v1.32.8 |

`versions.env` is the source of truth; the platform-owned pins actually deployed live in
`platform/bootstrap/*.yaml`.

## Local access

`make bootstrap` ends by running `bash scripts/95-port-forward.sh`, which forwards all six UIs
in the background and keeps running after the command that started it exits. Run it again
standalone any time (already bootstrapped, forwards died, whatever) - it's idempotent, stopping
anything it previously started before relaunching:

```bash
make port-forward         # (re)start all six
make port-forward-stop    # stop them
```

| UI | URL | Login |
|---|---|---|
| Argo CD | http://localhost:8080 | `admin` / see password command below |
| Tenant A Airflow | http://localhost:8081 | `admin` / `admin` (chart default) |
| Tenant B Airflow | http://localhost:8082 | `admin` / `admin` (chart default) |
| Headlamp | http://localhost:8083 | token, see command below - see all 3 clusters from the one UI |
| Vault | http://localhost:8200 | Token method, root token - see command below |
| SeaweedFS (filer - browse buckets/objects, incl. `tenant-a-logs`/`tenant-b-logs`) | http://localhost:8888 | none - no auth in front of the filer's own browser UI in this lab |

```bash
# Argo CD admin password
kubectl --context kind-af-mgmt -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d

# Headlamp login token
kubectl --context kind-af-mgmt -n headlamp create token \
  "$(kubectl --context kind-af-mgmt -n headlamp get sa -o jsonpath='{.items[0].metadata.name}')"

# Vault root token (from `make vault-init`'s output, gitignored under .local/)
jq -r '.root_token' .local/vault-keys.json
```

Forwarding just one tenant on a specific port also still works directly:
`make ui-airflow TENANT=tenant-a PORT=8081`.

**To run the full 3-cluster lab locally:** [`docs/runbook-bootstrap.md`](docs/runbook-bootstrap.md).
**To rehearse an Argo CD upgrade:** [`docs/runbook-argocd-upgrade.md`](docs/runbook-argocd-upgrade.md).
**To onboard a new tenant:** [`docs/runbook-tenant-onboarding.md`](docs/runbook-tenant-onboarding.md).
**To change a quota, a queue lane or a policy rule, or to check current governance status /
roll out Enforce:** `make governance-status`, `make governance-report`, `make governance-enforce`,
and [`docs/runbook-governance.md`](docs/runbook-governance.md).
**Something not working:** [`docs/troubleshooting.md`](docs/troubleshooting.md).
**To take this off KIND onto real infra (VKS 9 + AWS EKS, MinIO):** [`docs/HYBRID_MIGRATION_PLAN.md`](docs/HYBRID_MIGRATION_PLAN.md).

> Versions were originally pinned from documentation research without Helm-registry access, then
> corrected against a real local Helm install (Spark Operator was 4 minor releases stale at
> 2.1.1). CI's `verify-versions` job (`lint.yaml`) checks every pin against the real registries on
> every push - treat a failure there as the version needing an update, not a flaky check.
