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
- **CI in GitHub Actions**: lint, policy checks, rendered-manifest diffs on PRs, a reduced
  single-cluster KIND smoke test, and a nightly Argo CD upgrade rehearsal.

## Status

Bootstrapped and run end to end on a real local 3-cluster lab (not just CI). Argo CD, Vault, ESO,
Spark Operator, and both tenants' full Airflow stack (api-server/scheduler/dag-processor/
triggerer/postgres) are healthy on both clusters. `it_kubernetes_pod_operator` passes for both
tenants, local and cross-cluster. `it_spark`'s own bugs are fixed and each fix verified directly
(SparkApplications complete in both clusters), but a fully automated `make test-integration` run
can still be disrupted by an open Argo CD issue: `tenant-a-airflow`/`tenant-b-airflow` sit
persistently `OutOfSync` with `selfHeal: true`, so periodic re-syncs regenerate hook-created
Secrets and can invalidate an in-flight task - see
[`docs/troubleshooting.md`](docs/troubleshooting.md) for what's confirmed so far. See
[`docs/architecture.md`](docs/architecture.md) for the as-built design and every place it deviates
from the original plan, and [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) for the
original approved design.

## Versions

| Component | Version |
|---|---|
| Argo CD | 7.8.28 chart / v2.14.11 |
| HashiCorp Vault | 0.30.0 chart / 1.19.0 |
| External Secrets Operator | 0.10.4 |
| Kubeflow Spark Operator | 2.5.2 |
| Apache Airflow | 1.22.0 chart / 3.1.7 |
| Spark (jobs) | 3.5.3 |
| Postgres (metadata DB) | 16-alpine |
| KIND node image | v1.32.8 |

`versions.env` is the source of truth; the platform-owned pins actually deployed live in
`platform/bootstrap/*.yaml`.

## Local access

After `make bootstrap` (see the runbook):

| UI | Command | URL | Login |
|---|---|---|---|
| Argo CD | `make ui-argocd` | http://localhost:8080 | `admin` / `kubectl --context kind-af-mgmt -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| Tenant A Airflow | `make ui-airflow TENANT=tenant-a` | http://localhost:8081 | `admin` / `admin` (chart default) |
| Tenant B Airflow | `make ui-airflow TENANT=tenant-b PORT=8082` | http://localhost:8082 | `admin` / `admin` (chart default) |

**To run the full 3-cluster lab locally:** [`docs/runbook-bootstrap.md`](docs/runbook-bootstrap.md).
**To rehearse an Argo CD upgrade:** [`docs/runbook-argocd-upgrade.md`](docs/runbook-argocd-upgrade.md).
**To onboard a new tenant:** [`docs/runbook-tenant-onboarding.md`](docs/runbook-tenant-onboarding.md).
**Something not working:** [`docs/troubleshooting.md`](docs/troubleshooting.md).

> Versions were originally pinned from documentation research without Helm-registry access, then
> corrected against a real local Helm install (Spark Operator was 4 minor releases stale at
> 2.1.1). CI's `verify-versions` job (`lint.yaml`) checks every pin against the real registries on
> every push - treat a failure there as the version needing an update, not a flaky check.
