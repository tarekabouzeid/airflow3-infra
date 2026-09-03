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

Implemented. Built and validated without local Docker/Kubernetes access - GitHub Actions
(`.github/workflows/e2e-kind.yaml`) is the primary correctness check: it stands up a real Argo
CD, real Vault, real External Secrets Operator, real Spark Operator, and a real Airflow
deployment on a kind cluster, and runs both integration DAGs to completion. See
[`docs/architecture.md`](docs/architecture.md) for the as-built design and every place it
deviates from the original plan, and [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md)
for the original approved design.

**To run the full 3-cluster lab locally:** [`docs/runbook-bootstrap.md`](docs/runbook-bootstrap.md).
**To rehearse an Argo CD upgrade:** [`docs/runbook-argocd-upgrade.md`](docs/runbook-argocd-upgrade.md).
**To onboard a new tenant:** [`docs/runbook-tenant-onboarding.md`](docs/runbook-tenant-onboarding.md).
**Something not working:** [`docs/troubleshooting.md`](docs/troubleshooting.md).

> Every version pinned in `versions.env` was resolved from documentation research in an
> environment without Helm-registry access. CI's `verify-versions` job (`lint.yaml`) checks every
> one against the real registries on every push - treat a failure there as the version needing an
> update, not a flaky check.
