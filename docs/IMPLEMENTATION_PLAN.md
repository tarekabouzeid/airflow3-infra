# Multi-Tenant Airflow 3 on Kubernetes, Managed by Argo CD — Implementation Plan

## Context

`tarekabouzeid/airflow3-infra` is currently an empty repository. The goal is to build, entirely as
code, a reproducible local lab that models a production multi-tenant Airflow 3 platform:

- One central Argo CD manages Airflow deployments for multiple tenants across several clusters.
- Each tenant's configuration lives in its own GitHub repo; the platform repo owns the trust boundary.
- Tenants run workloads (Spark via the Kubeflow Spark Operator, and generic pods via
  KubernetesPodOperator) both in their home cluster and in a **remote** cluster.
- Secrets live in OSS HashiCorp Vault and reach both Airflow and the workload pods in every cluster.
- DAGs are delivered to a PVC by an init/loader job.
- The whole thing rebuilds from scratch on a laptop with KIND, and CI protects it from regressions.

The operator (the repo owner) has not run Argo CD before, so the deliverable is not just manifests —
it is manifests **plus runbooks** that explain the pattern and let them rehearse an Argo CD upgrade.

Decisions already made with the user:

| Decision | Choice |
|---|---|
| Tenant repos | Separate GitHub repos: `tarekabouzeid/airflow3-infra-tenant-a`, `tarekabouzeid/airflow3-infra-tenant-b` (already created; Claude GitHub App to be installed on them) |
| Cluster topology | 3 KIND clusters, 16GB+ RAM |
| Secrets | Hybrid — Airflow Vault secrets backend for Connections/Variables, ESO for workload-pod secrets |
| Argo CD upgrade rehearsal | Start on Argo CD v2.14.x, upgrade across the 3.0 major boundary, then to latest 3.x |

---

## ⚠️ Rule 0 for the implementing agent: verify every version before pinning

The planning session ran in a sandbox whose network egress blocked Helm registries, `api.github.com`,
`airflow.apache.org`, `argo-cd.readthedocs.io` and `artifacthub.io`. Version numbers below were
obtained via web *search* summaries of official docs, **not** by reading the registries directly.
They are starting points, not facts.

**Before writing any version into a file**, run the verification and use what it returns:

```bash
helm repo add argo         https://argoproj.github.io/argo-helm
helm repo add apache-airflow https://airflow.apache.org
helm repo add external-secrets https://charts.external-secrets.io
helm repo add hashicorp    https://helm.releases.hashicorp.com
helm repo add spark-operator https://kubeflow.github.io/spark-operator
helm repo update
helm search repo argo/argo-cd --versions | head -40
helm search repo apache-airflow/airflow --versions | head -10
helm search repo external-secrets/external-secrets --versions | head -5
helm search repo hashicorp/vault --versions | head -5
helm search repo spark-operator/spark-operator --versions | head -5
helm show values <chart> --version <v>   # read the real values schema before templating anything
```

Also verify:
- Argo CD v2.14's **tested Kubernetes versions** at
  `https://argo-cd.readthedocs.io/en/release-2.14/operator-manual/tested-kubernetes-versions/`
  and pick the KIND node image inside the overlap of (2.14 supported) ∩ (latest 3.x supported), so the
  same cluster survives the whole upgrade rehearsal.
- The KIND node image **digest** from the release notes of the installed `kind` version
  (`kind version`, then the matching release on `kubernetes-sigs/kind`).

If a verified value differs from this plan, use the verified value, update `versions.env`, and note
the correction in `docs/architecture.md`. Never invent a version or a values key — if `helm show
values` does not have the key, it does not exist.

**Starting points to verify (as of research date):**

| Component | Pin (verify!) | Notes |
|---|---|---|
| kind node image | `kindest/node:v1.32.8@sha256:abd489f042d2b644e2d033f5c2d900bc707798d075e8186cb65e3f1367a9d5a1` | k8s 1.32 chosen for 2.14↔3.x overlap |
| Argo CD chart (start) | `argo/argo-cd` 7.8.x → appVersion v2.14.x | chart 7.x ⇒ Argo CD 2.14.x |
| Argo CD chart (step 2) | 8.x → v3.0.x | crosses the documented breaking boundary |
| Argo CD chart (step 3) | latest 9.x/10.x → v3.x | |
| Airflow chart | `apache-airflow/airflow` 1.22.x, appVersion 3.1.x | |
| External Secrets | `external-secrets/external-secrets` latest | |
| Vault | `hashicorp/vault` latest | OSS |
| Spark Operator | `spark-operator/spark-operator` latest | Kubeflow |
| Spark image | `apache/spark:4.0.x` | must match operator's supported Spark |

---

## Architecture

### Cluster topology (3 KIND clusters, all on the shared `kind` Docker network)

```
┌─ af-mgmt ──────────────┐   ┌─ af-work-a ─────────────────┐   ┌─ af-work-b ────────────────┐
│ Argo CD (self-managed) │   │ ESO                         │   │ ESO                        │
│ Vault (OSS, standalone)│──▶│ Spark Operator              │   │ Spark Operator             │
│                        │   │ tenant-a-airflow (ns)       │   │ tenant-a-workloads (ns)    │
│ registers ─────────────┼──▶│ tenant-a-workloads (ns)     │   │ tenant-b-workloads (ns)    │
│  af-work-a, af-work-b  │   │ tenant-b-airflow (ns)       │◀──┤   ← remote KPO / Spark     │
└────────────────────────┘   │ tenant-b-workloads (ns)     │   └────────────────────────────┘
                             └─────────────────────────────┘
```

Every cluster is **single-node**. This is a hard requirement: KIND's default `local-path` storage
class is ReadWriteOnce, and the DAGs PVC is mounted by scheduler, dag-processor, api-server,
triggerer and every KubernetesExecutor worker pod. RWO works across pods only on the same node.
If a worker node is ever added, either pin those pods with `nodeAffinity` or install an RWX
provisioner — document this in `docs/architecture.md`.

**Cross-cluster addressing.** All KIND control-plane containers join the user-defined `kind` Docker
network, so Docker's embedded DNS resolves container names. From inside any cluster:
`https://af-work-b-control-plane:6443` and `http://af-mgmt-control-plane:8200` (Vault via NodePort)
resolve. This is what makes remote-cluster kubeconfigs and remote ESO→Vault work without host
port-forwards. `scripts/lib/common.sh` must derive these addresses from
`docker inspect`, never hardcode IPs.

### Argo CD strategy (the recommendation, and why)

**Layer 1 — bootstrap, once, imperatively.** `make bootstrap` creates the clusters and runs
`helm install argocd argo/argo-cd --version <old>` with `bootstrap/argocd-values.yaml`, then applies
one root Application. That is the only imperative step; everything after is GitOps.

**Layer 2 — Argo CD manages Argo CD.** `platform/bootstrap/app-argocd-self.yaml` is an Application
pointing at the `argo/argo-cd` chart with **the same values file from git**. Upgrading Argo CD then
becomes: bump `spec.source.targetRevision`, commit, sync. This is what makes the upgrade rehearsal a
GitOps exercise instead of a `helm upgrade`. Two gotchas to encode:
- Set `syncOptions: [ServerSideApply=true, Replace=true]` on the CRD-bearing sync — Argo CD's CRDs
  exceed the client-side-apply annotation limit.
- The app-controller restarts itself mid-sync; the Application may briefly show `Progressing` or
  `Unknown`. Document this in the upgrade runbook so it isn't mistaken for failure.

**Layer 3 — app-of-apps root.** `bootstrap/root-app.yaml` points at `platform/bootstrap/`, a
directory of child Applications and ApplicationSets, ordered with `argocd.argoproj.io/sync-wave`
annotations. App-of-apps is the right tool *here* — a small, static, platform-owned set of children.

**Layer 4 — ApplicationSets for the things that multiply.** This is the key recommendation:
**app-of-apps for the platform, ApplicationSets for tenants and clusters.** Do not let tenants author
`Application` resources in their own repos — accepting a tenant commit that changes an Application
spec means accepting arbitrary destination clusters and namespaces. Instead:

- `appset-platform-components.yaml` — **git directory generator** over
  `platform/clusters/*/*`. Each directory is one component for one cluster
  (`platform/clusters/af-work-a/external-secrets/`), and the generated Application's destination is
  derived from `{{.path.segments[1]}}` (the cluster name). Adding a component to a cluster = adding
  a directory. Verify the exact templating syntax against the ApplicationSet docs for the Argo CD
  version in use — the `{{path[1]}}` (2.x, Go text/template off) vs `{{.path.segments[1]}}`
  (goTemplate: true) difference is a real 2.14→3.x migration trap, and hitting it is instructive.
- `appset-tenants.yaml` — **matrix generator**: git *file* generator over
  `platform/tenants/*.yaml` (the tenant registry, **owned by the platform repo** = the trust
  boundary) crossed with each tenant's `clusters` list. Generates, per tenant:
  - `<tenant>-airflow` → home cluster, namespace `<tenant>-airflow`
  - `<tenant>-workloads-<cluster>` → one per target cluster, namespace `<tenant>-workloads`
- `appset-tenant-projects.yaml` — one Application per tenant rendering `charts/tenant-project`
  with that tenant's registry file as values. ApplicationSets cannot generate AppProjects directly,
  so they are rendered by a chart from the same single source of truth.

**Layer 5 — AppProject per tenant** (`charts/tenant-project`). This is where multi-tenancy is
actually enforced, and it must be tight:
- `sourceRepos`: only the platform repo + that tenant's repo.
- `destinations`: only `<tenant>-airflow` and `<tenant>-workloads` on the tenant's declared clusters.
- `clusterResourceWhitelist`: empty (tenants get no cluster-scoped resources).
- `namespaceResourceBlacklist`: `ResourceQuota`, `LimitRange`, `NetworkPolicy` — platform-owned.
- Per-project RBAC roles so a tenant can sync/see only their own apps.

The chart also renders, per tenant: namespaces, `ResourceQuota`, `LimitRange`, a default-deny
`NetworkPolicy` plus explicit allows, and the Airflow↔workload RBAC.

**Tenant Applications use Argo CD multi-source.** Source 1 = platform repo, `charts/airflow-tenant`
(platform owns the deployment shape). Source 2 = tenant repo with `ref: values`, contributing
`$values/deploy/airflow/values.yaml`. The tenant supplies values only; they cannot change the chart.
Multi-source is available in the 2.14 starting version — confirm behaviour is unchanged in 3.x during
the upgrade.

**Sync policy conventions** (encode in a `CLAUDE.md` convention doc):
`automated: {prune: true, selfHeal: true}`, `syncOptions: [CreateNamespace=true, ServerSideApply=true,
ApplyOutOfSyncOnly=true, PruneLast=true]`, and a `retry` backoff — ApplicationSet-generated
Applications can briefly race ahead of their AppProject and must self-heal.

### Airflow per tenant

- Chart `apache-airflow/airflow`, wrapped by `charts/airflow-tenant` (umbrella chart with the
  official chart as a dependency, plus the platform's own glue templates).
- **Executor: KubernetesExecutor.** Task = pod, no Celery/Redis, lightest and most k8s-native.
- **Metadata DB: our own minimal Postgres** (`charts/postgres-lite`, official `postgres:16-alpine`),
  with `postgresql.enabled=false` on the Airflow chart and `data.metadataConnection` pointed at it.
  Rationale: the bundled Bitnami subchart is an external dependency whose image locations changed in
  2025; owning a 40-line StatefulSet is more reproducible for a lab. Flag this choice in the docs.
- **Custom image** built from `apache/airflow:3.1.x` adding `apache-airflow-providers-hashicorp`
  (the Vault secrets backend is not in the base image). Built by `make images` and pushed to a local
  registry container (`kind-registry:5000`) wired into all three clusters using KIND's documented
  local-registry pattern — do not use `kind load docker-image`, it does not scale to 3 clusters.
- **DAGs on a PVC, populated by a loader Job** (as requested):
  `dags.persistence.enabled: true`, `existingClaim: <tenant>-dags`, `accessMode: ReadWriteOnce`.
  A `<tenant>-dag-loader` Job with `argocd.argoproj.io/hook: PostSync` and
  `hook-delete-policy: BeforeHookCreation` shallow-clones the tenant repo and copies `dags/` onto the
  PVC. So `git push` → Argo CD sync → DAGs refreshed, with no git-sync sidecars.
- **Vault secrets backend** via env on all Airflow components:
  `AIRFLOW__SECRETS__BACKEND=airflow.providers.hashicorp.secrets.vault.VaultBackend` and
  `AIRFLOW__SECRETS__BACKEND_KWARGS` = `{"connections_path":"connections","variables_path":"variables",
  "mount_point":"<tenant>","config_path":null,"auth_type":"kubernetes",
  "kubernetes_role":"<tenant>-airflow","url":"http://af-mgmt-control-plane:8200"}`.
  Set `config_path: null` so Airflow does not hammer Vault for config lookups.
  Pin one custom ServiceAccount name across scheduler/dag-processor/worker/triggerer/api-server so a
  single Vault role binds cleanly.

### Secrets: who gets what from where

| Consumer | Mechanism | Why |
|---|---|---|
| Airflow Connections & Variables | Vault backend, Kubernetes auth, per-tenant KV mount | No k8s Secret sprawl; rotation is immediate; isolation enforced by Vault policy |
| Spark driver/executor pods, KPO pods (home **and** remote cluster) | ESO `SecretStore` (namespaced, not Cluster — tighter) → `ExternalSecret` → k8s Secret | Those pods cannot call Vault themselves |

Vault layout per tenant: KV-v2 mount `tenant-a/`, with `connections/`, `variables/` and
`workload-secrets`. Policies: `tenant-a-airflow` (read `tenant-a/data/connections/*`,
`tenant-a/data/variables/*`) and `tenant-a-eso` (read `tenant-a/data/workload-secrets`).

**Multi-cluster Vault auth is the subtle part.** Kubernetes auth validates a SA token against *one*
cluster's TokenReview API, so each cluster needs its **own auth mount**: `kubernetes-mgmt`,
`kubernetes-work-a`, `kubernetes-work-b`. Each is configured with that cluster's in-network API URL,
its CA, and a `token_reviewer_jwt` from a dedicated `vault-token-reviewer` SA in that cluster
(bound to `system:auth-delegator`). Roles are then bound per mount to the right SA + namespace.
Vault configuration is done by an **idempotent** `scripts/60-vault-configure.sh` using the `vault`
CLI (mention `terraform-provider-vault` in the docs as the production path; a script keeps the lab's
toolchain small).

Vault runs **standalone with file storage**, not dev mode, so init/unseal is a real exercise:
`make vault-init` writes unseal keys to `.local/vault-keys.json` (gitignored), `make vault-unseal`
after any restart. Document the `server.dev.enabled=true` fallback for anyone who wants it.

### Remote workload execution

`scripts/70-remote-access.sh` (idempotent) does, per tenant:
1. In `af-work-b`: create SA `<tenant>-runner` in `<tenant>-workloads`, a Role granting
   pods/pods-log/pods-exec CRUD + `sparkoperator.k8s.io/sparkapplications`, and a bound long-lived
   SA token Secret.
2. Build a kubeconfig whose `server` is `https://af-work-b-control-plane:6443` (in-network name).
3. Write it to Vault at `<tenant>/connections/k8s_remote` shaped as an Airflow Kubernetes connection
   (`conn_type: kubernetes`, `extra: {"kube_config": "<yaml>", "in_cluster": false}`) — verify the
   exact extra-field names against the cncf-kubernetes provider connection docs before writing.

Airflow then reaches the remote cluster with `kubernetes_conn_id="k8s_remote"` on both
`KubernetesPodOperator` and `SparkKubernetesOperator`. Same Vault-backed mechanism, both operators —
that is the payoff of the hybrid secrets choice.

### Integration tests (2 per tenant, deliberately tiny)

Both live in the tenant repo's `dags/`:

- `it_kubernetes_pod_operator.py` — one DAG, two tasks: a `busybox` pod locally (`in_cluster`), and
  the same pod on `af-work-b` via `kubernetes_conn_id="k8s_remote"`. Each echoes a value mounted from
  the ESO-synced `<tenant>-workload` Secret, proving Vault→ESO→pod in both clusters at once.
- `it_spark.py` — `SparkKubernetesOperator` submitting `dags/spark/spark_pi.yaml` (spark-pi,
  `spark.executor.instances: 1`, 512Mi driver/executor, official `apache/spark:4.0.x`), with the same
  local/remote pair. Confirm current `SparkKubernetesOperator` arguments (`application_file` vs
  `template_spec`) against the provider docs for the pinned provider version — this API changed.

Keep both DAGs `catchup=False`, `schedule=None`, `max_active_runs=1`, with `retries=0` so failures
surface immediately.

---

## Repository layout

### `tarekabouzeid/airflow3-infra` (platform, branch `claude/airflow3-argocd-multitenant-fog99x`)

```
CLAUDE.md                       # conventions for future Claude Code sessions (see below)
Makefile                        # every operation has a target; targets are idempotent
versions.env                    # SINGLE source of truth for every version/digest
README.md                       # 10-minute quickstart
docs/architecture.md            # diagrams + why each decision
docs/runbook-bootstrap.md
docs/runbook-argocd-upgrade.md  # the 2.14 → 3.0 → 3.x rehearsal, step by step
docs/runbook-tenant-onboarding.md
docs/troubleshooting.md
kind/af-mgmt.yaml  kind/af-work-a.yaml  kind/af-work-b.yaml
scripts/
  lib/common.sh                 # logging, retries, docker-network address discovery
  00-preflight.sh               # docker/kind/helm/kubectl/jq/vault versions + RAM check
  10-create-clusters.sh   20-local-registry.sh   30-install-argocd.sh
  40-register-clusters.sh 50-vault-init.sh       60-vault-configure.sh
  70-remote-access.sh     80-seed-tenant-secrets.sh
  90-run-integration-tests.sh   99-teardown.sh
bootstrap/argocd-values.yaml    # used by BOTH the imperative install and the self-managed App
bootstrap/root-app.yaml
platform/
  bootstrap/{app-argocd-self.yaml,appset-platform-components.yaml,
             appset-tenant-projects.yaml,appset-tenants.yaml}
  clusters/af-mgmt/vault/
  clusters/af-work-a/{external-secrets,spark-operator}/
  clusters/af-work-b/{external-secrets,spark-operator}/
  tenants/{tenant-a.yaml,tenant-b.yaml}          # tenant registry — the trust boundary
charts/
  tenant-project/     # AppProject, namespaces, quota, limits, NetworkPolicy, RBAC
  airflow-tenant/     # umbrella: apache-airflow/airflow dep + postgres-lite + dag-loader + Vault glue
  postgres-lite/
images/airflow/Dockerfile
tests/{fixtures/,test_render.py,policy/*.rego}
.github/workflows/{lint.yaml,render-diff.yaml,policy.yaml,e2e-kind.yaml,argocd-upgrade.yaml}
renovate.json
```

### `tarekabouzeid/airflow3-infra-tenant-{a,b}`

```
README.md
deploy/airflow/values.yaml      # small: image tag, resources, Vault mount, remote cluster list
deploy/workloads/               # helm chart: SecretStore, ExternalSecret, SA/RBAC, per-cluster values
dags/it_kubernetes_pod_operator.py
dags/it_spark.py
dags/spark/spark_pi.yaml
tests/test_dags_import.py
.github/workflows/{lint.yaml,dag-validate.yaml}
```

`deploy/workloads` is a chart, not raw manifests, because the same content deploys to two clusters
with a different Vault Kubernetes auth mount path each; the ApplicationSet passes `cluster` as a
Helm parameter.

### `CLAUDE.md` conventions to write into the platform repo

- Never introduce a version that is not in `versions.env`; never bump one without checking the
  upstream release notes in the same commit.
- Never write a Helm values key without confirming it in `helm show values` for the pinned version.
- Every script is idempotent and safe to re-run; every script sets `set -euo pipefail`.
- Run `make lint` (helm template + kubeconform + conftest) before every commit.
- Never hardcode IPs; derive addresses from `docker inspect` via `scripts/lib/common.sh`.
- Secrets never enter git; `.local/` is gitignored.

---

## Implementation phases

Each phase ends with a stated verification command and a commit. Do not start a phase before the
previous phase's verification passes.

| # | Phase | Deliverable | Verification |
|---|---|---|---|
| 0 | Skeleton | `CLAUDE.md`, `Makefile`, `versions.env` (all versions **verified** per Rule 0), docs stubs, `scripts/lib/common.sh`, `00-preflight.sh`, `.gitignore` | `make preflight` passes |
| 1 | Clusters | 3 KIND configs, local registry, `make clusters` | 3 clusters up; a pod in `af-work-a` resolves and reaches `af-work-b-control-plane:6443`; registry push/pull works from all 3 |
| 2 | Argo CD | Install at **v2.14.x**, `bootstrap/argocd-values.yaml`, root app, self-management app, declarative cluster secrets for the two work clusters | `argocd version` shows 2.14.x; `argocd cluster list` shows 3; the `argocd` Application is Synced/Healthy (self-managing) |
| 3 | Platform components | `appset-platform-components.yaml` + per-cluster dirs for ESO, Spark Operator, Vault | All generated Applications Synced/Healthy; CRDs present in the right clusters |
| 4 | Vault | `50-vault-init.sh`, `60-vault-configure.sh` (3 k8s auth mounts, per-tenant KV + policies + roles) | `vault status` unsealed; a test pod in `af-work-b` logs in via `kubernetes-work-b` and reads its tenant path; a pod in another tenant's ns is **denied** |
| 5 | Tenant scaffolding | `charts/tenant-project`, `platform/tenants/*.yaml`, `appset-tenant-projects.yaml` | AppProjects exist; `argocd app create` targeting a foreign namespace is **rejected** by the project |
| 6 | Tenant A Airflow | `charts/airflow-tenant`, `charts/postgres-lite`, custom image, dag-loader Job, multi-source Application | Airflow 3 UI reachable; DAGs from the tenant repo appear; `airflow connections get k8s_remote` resolves **from Vault** |
| 7 | Tenant B | Add `platform/tenants/tenant-b.yaml` + scaffold tenant-b repo — nothing else | Tenant B appears and syncs with **one file added** to the platform repo. If it took more, the abstraction is wrong — fix it before continuing |
| 8 | Workloads + remote | `deploy/workloads` chart on both clusters; `70-remote-access.sh`; ESO SecretStore/ExternalSecret per tenant per cluster | The `<tenant>-workload` Secret exists in `tenant-a-workloads` on **both** clusters with matching values; a manual pod on `af-work-b` mounts it |
| 9 | Integration tests | The 2 DAGs per tenant + `90-run-integration-tests.sh` (trigger, poll, assert, dump logs on failure) | `make test-integration` green for both tenants: 4 DAG runs, 8 tasks, local + remote each |
| 10 | CI | The 5 workflows below | Green on a PR; deliberately break a chart value and confirm CI catches it |
| 11 | Upgrade rehearsal | `docs/runbook-argocd-upgrade.md`, executed for real: 2.14 → 3.0 → latest 3.x | After each hop: Argo CD reports the new version, **all** Applications return Synced/Healthy, and `make test-integration` still passes |

---

## CI (GitHub Actions)

**Platform repo:**

1. `lint.yaml` (every PR, ~3 min) — `actionlint`, `shellcheck`, `yamllint`, `helm lint` +
   `helm template` for every chart against `tests/fixtures/`, `kubeconform` with CRD schemas for
   Application/AppProject/ApplicationSet/ExternalSecret/SecretStore/SparkApplication, and a guard
   that every version referenced in a manifest exists in `versions.env`.
2. `policy.yaml` (every PR) — `conftest` over rendered output: no Application in the `default`
   project; every tenant Application's destination namespace is prefixed with its tenant name; no
   `:latest` images; `prune`/`selfHeal` not silently disabled on platform apps; tenant AppProjects
   have an empty `clusterResourceWhitelist`.
3. `render-diff.yaml` (every PR) — render manifests for base vs head, post the diff as a PR comment.
   This is the single highest-value habit for GitOps review.
4. `e2e-kind.yaml` (PR label `e2e` + nightly) — reduced **single-cluster** smoke on a GH runner via
   `helm/kind-action`: Argo CD (old version) + Vault dev + ESO + Spark Operator + tenant-a Airflow,
   wait for Synced/Healthy, run the local half of both integration DAGs. Be explicit in the docs that
   full 3-cluster / remote-execution testing is **local-only** — a GH runner cannot host it. Time-box
   to 35 min with `timeout-minutes` and always upload `kubectl describe`/logs as artifacts.
5. `argocd-upgrade.yaml` (nightly + manual) — the workflow that most directly protects the user's
   stated goal: install old Argo CD, apply the root app, bump the chart version, assert every
   Application returns to Synced/Healthy. Combined with **Renovate** (`renovate.json`) opening chart
   bump PRs, every future Argo CD/Airflow/ESO bump arrives pre-tested.

**Tenant repos:** `dag-validate.yaml` (install Airflow 3 + cncf-kubernetes + hashicorp providers,
`DagBag` import check with zero import errors, `ruff`) and `lint.yaml` (`helm template
deploy/workloads` + `kubeconform` + `yamllint`).

---

## Verification (end-to-end, local)

```bash
make preflight          # tool versions, RAM, docker
make bootstrap          # clusters + registry + argocd(old) + root app   (~15 min)
make vault-init         # init/unseal, keys to .local/ (gitignored)
make vault-configure    # 3 k8s auth mounts, tenant KV mounts, policies, roles
make remote-access      # remote SA + kubeconfig into Vault per tenant
make status             # every Application: Synced/Healthy
make test-integration   # both tenants × {KPO, Spark} × {local, remote} = 8 tasks
make upgrade-argocd VERSION=<3.0.x chart>   # then re-run make status && make test-integration
make teardown
```

Manual checks worth doing once, and worth writing into `docs/troubleshooting.md`:

- Argo CD UI (`make ui-argocd`): confirm the tenant-a AppProject blocks a deliberate attempt to sync
  into `tenant-b-airflow`.
- Airflow UI (`make ui-airflow TENANT=tenant-a`): confirm `k8s_remote` resolves from Vault and is
  **not** present as a Kubernetes Secret anywhere.
- `kubectl --context kind-af-work-b get pods -n tenant-a-workloads -w` while the remote DAG runs.

---

## Open items to resolve at implementation time

1. **Tenant repo access.** The implementing session needs `tarekabouzeid/airflow3-infra-tenant-a`
   and `-tenant-b` added to its scope (Claude GitHub App installed on both). Until then, scaffold
   their contents under `tenants-scaffold/tenant-{a,b}/` in the platform repo and provide
   `scripts/push-tenant-scaffold.sh` so the user can push them manually. Do not block other phases
   on this.
2. **Argo CD 2.14 vs the chosen k8s version** — resolve per Rule 0 before creating the clusters; it
   determines the KIND node image for the whole lab.
3. **ApplicationSet templating syntax** differs between the 2.14 starting point and 3.x
   (`goTemplate`/`goTemplateOptions`). Write the ApplicationSets in whichever form 2.14 supports,
   and make migrating them an explicit, documented step of the upgrade runbook — it is one of the
   most likely things to actually break, which makes it good practice.
4. **`SparkKubernetesOperator` API** — verify argument names against the pinned cncf-kubernetes
   provider docs; this operator's interface changed across provider versions.
