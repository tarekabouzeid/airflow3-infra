# Conventions for working in this repo

This repo is a multi-tenant Airflow 3 + Argo CD platform, built as infrastructure-as-code and
intended to be rebuilt from scratch (locally on KIND, or partially in GitHub Actions CI). See
`docs/IMPLEMENTATION_PLAN.md` for the full design and rationale, and `docs/architecture.md` for
the as-built architecture.

## Hard rules

1. **Never introduce a version not in `versions.env`.** It is the single source of truth for every
   chart version, image tag, and appVersion. Update it, don't hardcode elsewhere.
2. **Never write a Helm values key without confirming it exists** for the pinned chart version
   (`helm show values <repo>/<chart> --version <v>`). If CI's `helm template` step doesn't
   recognize a key, that's a sign of a hallucinated key, not a linter bug.
3. **Every shell script is idempotent** — safe to re-run, and safe to run out of order after a
   partial failure. `set -euo pipefail` at the top of every script.
4. **Never hardcode IPs or hostnames.** Cross-cluster addresses are derived at runtime from
   `docker inspect` via `scripts/lib/common.sh`. KIND container names on the shared `kind` Docker
   network are stable; IPs are not guaranteed to be.
5. **Secrets never enter git.** `.local/` is gitignored and holds Vault unseal keys, kubeconfigs,
   etc. Nothing under it is ever committed.
6. **Tenants never author `Application`/`ApplicationSet` resources.** The trust boundary is the
   `platform/tenants/*.yaml` registry (platform-owned) plus a per-tenant `AppProject`. Tenant repos
   contribute Helm values and DAGs only.
7. **No `:latest` image tags** in anything actually deployed (the Dockerfile base image and
   `versions.env` entries marked `"latest"` are resolved to a concrete tag by CI/scripts before
   use — grep for `TODO(pin)` if one slips through).
8. **Governance rules are platform-owned and live in `charts/cluster-governance`.** Tenants
   choose a Kueue lane (`kueue.x-k8s.io/queue-name`) and nothing else; gang scheduling, lane
   sizing, the registry allowlist, resource ceilings and Pod Security are cluster-wide. Never
   widen a rule to make a specific workload pass — change the workload, or change the rule
   deliberately with a test for it. New rules ship `failureAction: Audit` first; see
   `docs/runbook-governance.md`.
9. **A Kyverno policy that fails to load is not an error anywhere.** It renders, validates against
   the CRD, applies cleanly, and then evaluates nothing — which in Audit mode produces an empty
   PolicyReport indistinguishable from compliance. Every rule needs an assertion in
   `tests/kyverno/kyverno-test.yaml`; the suite fails on any uncovered rule and on any policy
   Kyverno reports as invalid.
10. **This environment has no local Docker/KIND/Helm access.** GitHub Actions is the verification
   loop: `lint.yaml` renders and validates every chart, `e2e-kind.yaml` stands up real cluster(s)
   on the runner, `argocd-upgrade.yaml` rehearses the upgrade path. Treat a CI failure as ground
   truth, not a flake, unless proven otherwise.

## Before every commit

Run (or let CI run, if tools are unavailable locally):
```
helm lint charts/*
helm template <chart> --values tests/fixtures/<fixture>.yaml | kubeconform -strict -summary
yamllint .
shellcheck scripts/**/*.sh
conftest test --policy tests/policy <rendered-output>
python3 tests/kyverno/run.py                  # governance policies behave as documented
python3 tests/check_quota_invariant.py        # Kueue ceiling fits the namespace ResourceQuota
```

## Repository map

- `platform/` — GitOps source of truth Argo CD watches (bootstrap apps, ApplicationSets, per-cluster
  component manifests, the tenant registry).
- `charts/` — Helm charts owned by the platform (`tenant-project`, `airflow-tenant`,
  `postgres-lite`, `cluster-governance`, `tenant-queue`).
- `scripts/` — numbered, idempotent bootstrap/operations scripts for a real local KIND lab.
- `kind/` — KIND cluster configs for `af-mgmt`, `af-work-a`, `af-work-b`.
- `images/airflow/` — custom Airflow image (adds the Vault provider).
- `.github/workflows/` — CI: lint, policy, render-diff, e2e-kind (real KIND on the runner),
  argocd-upgrade (rehearses the 2.14→3.0→latest path).
- `tests/` — chart-render fixtures, OPA/conftest policies, the Kyverno policy suite
  (`tests/kyverno/`, run with `python3 tests/kyverno/run.py`), and the cross-cutting checks
  (`validate_against_crds.py`, `render_appset_values.py`, `check_quota_invariant.py`).

Tenant repos (`airflow3-infra-tenant-a`, `-b`) hold only: Helm values for their Airflow deployment,
a small `deploy/workloads` chart (ESO SecretStore/ExternalSecret + RBAC), and their DAGs.
