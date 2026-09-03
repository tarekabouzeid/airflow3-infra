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

Design complete, implementation not started.

**Start here: [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md)** — the full architecture,
the Argo CD strategy and the rationale behind it, the repository layout, and a phased build order
where every phase has an explicit verification gate.

> **Note for whoever implements this:** read "Rule 0" at the top of the plan first. Every version
> number in the plan is a researched starting point, not a verified fact — the planning session ran
> without network access to the Helm registries. Verify each one against the upstream registry and
> official docs before pinning it.
