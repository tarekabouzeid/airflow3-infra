# Architecture (as built)

This is the as-built reference. `docs/IMPLEMENTATION_PLAN.md` is the original design document
approved before implementation; where this repo diverges from it, that divergence and its reason
is called out below.

## Cluster topology

Three single-node KIND clusters, all on the shared `kind` Docker network so container-name
addressing works (`https://af-work-b-control-plane:6443` resolves from any of the three):

- **af-mgmt** - Argo CD (self-managed) + Vault (OSS, standalone, file storage) + Headlamp
  (Kubernetes web UI, with read/write access to af-work-a/af-work-b too - see "Headlamp" below).
- **af-work-a** - tenant-a's Airflow (home), tenant-a-workloads (local), tenant-b-workloads (remote).
- **af-work-b** - tenant-b's Airflow (home), tenant-b-workloads (local), tenant-a-workloads (remote).

tenant-a and tenant-b are deliberately mirrored (home/remote swapped) so the two tenants together
exercise both clusters as "home" and as "remote".

Every cluster is single-node: the DAGs PVC uses the default `local-path` (ReadWriteOnce) storage
class and is mounted by every Airflow component including ephemeral KubernetesExecutor worker
pods - RWO only works when every pod lands on the same node.

The official Airflow chart's persistent logs volume (`logs.persistence`) is disabled for the same
reason, but cannot simply be pinned to ReadWriteOnce like the DAGs PVC: the chart hardcodes that
PVC's access mode to ReadWriteMany with no values-schema key to override it (confirmed: `helm
template` rejects `logs.persistence.accessMode` as an unknown property), and `local-path` only
provisions ReadWriteOnce/ReadWriteOncePod. With it disabled, each task's logs live only in the pod
that produced them and are lost once that pod is gone - a real limitation of this lab, not
currently worked around with remote logging (e.g. S3/GCS), which would be the production fix.

## Argo CD strategy

- **Bootstrap** (`scripts/30-install-argocd.sh`): one `helm install` on af-mgmt, then one
  `kubectl apply -f bootstrap/root-app.yaml`. Everything after this is GitOps.
- **Self-management** (`platform/bootstrap/app-argocd-self.yaml`): Argo CD's own Application
  points at the `argo/argo-cd` chart with `bootstrap/argocd-values.yaml` from git. Upgrading Argo
  CD = bump `targetRevision`, commit, sync (see `docs/runbook-argocd-upgrade.md`).
- **App-of-apps** (`bootstrap/root-app.yaml` -> `platform/bootstrap/`): a small, static,
  platform-owned directory - the self-management Application, the platform-component Applications
  (Vault, Headlamp, and one External-Secrets + one Spark-Operator per workload cluster), and 3
  ApplicationSets for the tenant layer.
- **ApplicationSets for tenants** (the thing that actually multiplies):
  - `appset-tenant-projects.yaml` - one Application per tenant, rendering
    `charts/tenant-project` (scope=project): the `AppProject` that is the real trust boundary.
  - `appset-tenant-airflow.yaml` - one **multi-source** Application per tenant: the namespace
    guardrails (`charts/tenant-project`, scope=namespace) + the platform's Airflow chart
    (`charts/airflow-tenant`) + the tenant's own repo (`ref: values` only, contributing
    `deploy/airflow/values.yaml`). Inline values from the ApplicationSet template take
    precedence over the tenant's file, so a tenant cannot override platform-controlled wiring
    (Vault mount, ServiceAccount, DAG source) even by accident.
  - `appset-tenant-workloads.yaml` - one multi-source Application per (tenant, workload cluster):
    namespace guardrails + the tenant's own `deploy/workloads` chart (SecretStore/ExternalSecret).
    Tenants own this chart directly - it only ever touches their own namespace, which the
    AppProject already restricts them to.
  - All three generators are **git `files` generators** over
    `platform/tenants/<tenant>/*.yaml` - one committed file per generated Application, no
    matrix/fan-out generator needed. Onboarding tenant-b was: one `tenant.yaml` (home cluster,
    repo URL, Vault mount) plus one `workloads-<cluster>.yaml` per cluster it targets.
- **Wildcard AppProject destinations** (`{server: "*", namespace: "<tenant>-*"}`) rather than an
  enumerated per-cluster list: adding a remote cluster for an existing tenant needs no AppProject
  change, only a new `workloads-<cluster>.yaml` file.
- **`goTemplate: true`** is set on every ApplicationSet from the start, specifically to sidestep
  the fasttemplate -> goTemplate default flip that otherwise lands between the Argo CD 2.14 and
  3.x chart lines used in the upgrade rehearsal.

### Deviation from the original plan: platform components are static Applications, not an ApplicationSet

The original plan called for a git-*directory*-generator ApplicationSet scanning
`platform/clusters/*/<component>/`, deriving each destination cluster from the matched path.
Implementing that requires mapping a path segment (a cluster *name*) to that cluster's API
*server URL* inside the ApplicationSet template, which Argo CD's generators do not support
without extra plumbing (a second generator, or a static lookup table). With only 2-3 clusters and
3 platform component types, that plumbing bought nothing an ApplicationSet is actually good at
(it doesn't reduce file count or onboarding effort). The 5 component Applications are committed
directly in `platform/bootstrap/`. The tenant layer, which genuinely multiplies, still uses
ApplicationSets as designed.

## Secrets

Two mechanisms, one per consumer, as planned:

| Consumer | Mechanism |
|---|---|
| Airflow Connections & Variables | `apache-airflow-providers-hashicorp` VaultBackend, Kubernetes auth, per-tenant KV-v2 mount |
| Everything else that needs a k8s Secret (workload pods, the metadata-DB password, the dag-loader's git token) | External Secrets Operator, namespaced `SecretStore` per namespace |

Every cluster that hosts Vault-authenticating workloads has its **own** Vault Kubernetes auth
mount (`kubernetes-work-a`, `kubernetes-work-b`) - Kubernetes auth validates a token against one
cluster's TokenReview API, so one mount per cluster is required, each backed by a dedicated
`vault-token-reviewer` ServiceAccount bound to `system:auth-delegator` in that cluster
(`scripts/60-vault-configure.sh`). There is no `kubernetes-mgmt` mount: nothing running on
af-mgmt (where Vault itself lives) currently authenticates back into Vault via Kubernetes auth.

Per tenant, one KV-v2 mount (`tenant-a/`) holds `connections/*`, `variables/*`, `db` (the
Postgres credential, generated once, never in git), `git` (a GitHub token for the dag-loader Job
to clone the tenant's private repo), and `workload-secrets` (read back by the integration DAGs).
Two Vault roles per tenant: `<tenant>-airflow` (bound to the Airflow ServiceAccount, home cluster
only) and `<tenant>-eso` (bound to both the Airflow ServiceAccount and the workload-runner
ServiceAccount, on every cluster that has one of those namespaces).

### Metadata-DB connection: a Secret, not inline values

`values.yaml` is never templated by Helm, so a per-tenant Postgres hostname/password cannot be
computed inline there. Instead `charts/airflow-tenant/templates/postgres-db-externalsecret.yaml`
(a real template, which *is* rendered) builds the full `postgresql://user:pass@host:5432/db` URI
from Vault-sourced fields and an in-template `{{ .Release.Name }}-postgres` hostname, and the
airflow subchart is pointed at it via `data.metadataSecretName` - never `data.metadataConnection`
inline fields.

## Airflow per tenant

- KubernetesExecutor, standalone `dagProcessor`, `apiServer` (Airflow 3's UI+API process,
  replacing the Airflow 2 "webserver" chart key), logs on a chart-managed PVC.
- Metadata DB: `charts/postgres-lite`, a ~40-line StatefulSet on the official `postgres:16-alpine`
  image, not the Airflow chart's bundled Bitnami subchart - one fewer external image-registry
  dependency for a lab whose whole point is rebuilding reliably from scratch.
- DAGs: a PVC owned by `charts/airflow-tenant` (not the airflow chart's own PVC lifecycle), filled
  by a PostSync-hook Job (`dagLoader`) that shallow-clones the tenant's repo with a Vault-sourced
  GitHub token. `dagLoader.enabled: false` is used only by the CI smoke test, which has no tenant
  repo to clone from and seeds the PVC directly with `kubectl cp` instead.
- Custom image (`images/airflow/Dockerfile`): `apache/airflow:3.1.7` plus
  `apache-airflow-providers-hashicorp` and `apache-airflow-providers-cncf-kubernetes`, installed
  against Airflow's own published constraints file for the exact Airflow + Python version, so
  provider versions are never hand-pinned out of sync with Airflow core.
- `serviceAccount.name` is a **prefix**, not a literal name: the official chart suffixes it per
  component (`tenant-a-airflow-scheduler`, `-worker` for KubernetesExecutor pods, etc. - confirmed
  by CI, not assumed). Rather than track every derived name, Vault roles for this namespace bind
  `bound_service_account_names="*"` and rely on `bound_service_account_namespaces` for the actual
  tenant boundary (see `scripts/60-vault-configure.sh`); the one k8s-native RBAC RoleBinding that
  needs a subject (letting the home cluster's Airflow identity reach its local workloads
  namespace) binds to the `system:serviceaccounts:<namespace>` group instead of a named
  ServiceAccount, for the same reason.

## Headlamp

`platform/bootstrap/headlamp-af-mgmt.yaml` deploys Headlamp on af-mgmt only - it isn't part of any
tenant's execution path, just a Kubernetes web UI for humans. `config.inCluster: true` gives it
af-mgmt via its own pod ServiceAccount (chart default: bound to `cluster-admin`, same as every
other cluster it can see). `scripts/45-seed-headlamp-kubeconfigs.sh` gives it af-work-a and
af-work-b too, following the same pattern as `scripts/40-register-clusters.sh`'s
`argocd-manager`/`scripts/70-remote-access.sh`'s per-tenant kubeconfigs: mint a token for a
dedicated ServiceAccount (`headlamp-manager`, bound to `cluster-admin`) on each workload cluster,
build a standalone kubeconfig, and store both under one `headlamp-kubeconfigs` Secret in the
`headlamp` namespace on af-mgmt (never committed - it embeds live bearer tokens) that the
Application's Helm values mount and point the headlamp-server `-kubeconfig` flag at
(`config.extraArgs` - not the `KUBECONFIG` env var, which is not read by headlamp-server;
confirmed live against a real 3-cluster lab, see `platform/bootstrap/headlamp-af-mgmt.yaml`).
Until that script runs, the pod may sit erroring on the two missing kubeconfig paths and
self-heals once it does (the script also restarts
the Deployment itself, since a Secret change alone doesn't make Headlamp re-read the mounted
files) - the same "up but not yet usable" shape Vault has before `make vault-init`.

`config.unsafeUseServiceAccountToken: true` is also set, deliberately. By default Headlamp asks
every browser session to supply its own token before showing any cluster - confirmed live that
af-work-a/af-work-b (kubeconfig-sourced, a bearer token already embedded) proxy fine with no
per-user token at all, but af-mgmt (in-cluster) returns `403 system:anonymous` without one, and
that in-cluster check is what gates Headlamp's whole login screen. This setting makes af-mgmt use
the pod's own cluster-admin-bound ServiceAccount token the same way, removing the prompt entirely.
The chart's own name for it ("UNSAFE...only safe behind an auth proxy") is about collapsing every
user into one shared identity - a real concern for a shared or network-exposed instance, not for
this one, which is only ever reached via `kubectl port-forward` to localhost by the one lab
operator (the same threat model this repo already accepts elsewhere: cluster-admin SAs
everywhere, tenant Airflow's `admin`/`admin` default login).

## Remote workload execution

`scripts/70-remote-access.sh` mints a long-lived token for the `<tenant>-workload-runner`
ServiceAccount that `charts/tenant-project` already created (via GitOps) in the *remote* cluster's
`<tenant>-workloads` namespace, builds a kubeconfig, and writes it into Vault at
`<mount>/connections/k8s_remote` as a structured Kubernetes connection
(`conn_type=kubernetes`, `extra={"kube_config": ..., "in_cluster": false}`). Both
`KubernetesPodOperator` and `SparkKubernetesOperator` then reach the remote cluster with
`kubernetes_conn_id="k8s_remote"` - same Vault-backed mechanism, both operators.

## CI scope (why e2e-kind.yaml is one cluster, not three)

This repo was built without local Docker/Kubernetes access, so GitHub Actions is the primary
verification loop, not a human running `make bootstrap` - `.github/workflows/e2e-kind.yaml`
actually stands up a real Argo CD, real Vault (init/unseal/configure), real External Secrets
Operator, real Spark Operator, and a real Airflow deployment, and runs both integration DAGs to
completion. It intentionally does **not** attempt the full 3-cluster topology: a single
GitHub-hosted runner cannot host 3 KIND clusters plus this workload set reliably, and the
cross-cluster Docker networking this platform depends on is easiest to reason about on a single
Docker host anyway (a laptop). In CI, "remote" execution is simulated by pointing
`k8s_remote` back at the *same* cluster via an explicit kubeconfig rather than the in-cluster
identity - which still exercises the real "external Kubernetes connection" code path in both
operators, just not real cross-cluster networking. The full 3-cluster rehearsal is the local flow
in `docs/runbook-bootstrap.md`. For the same one-cluster-runner reason, `e2e-kind.yaml` does not
deploy Headlamp at all: its whole point (af-work-a/af-work-b reachability via
`scripts/45-seed-headlamp-kubeconfigs.sh`) needs clusters that don't exist there. `lint.yaml`
(chart-version verification) and `policy.yaml` (static Application manifest) still cover it; the
3-cluster reachability itself is only proven by the local bootstrap flow.

The tenant layer in `e2e-kind.yaml` is applied with `helm template | kubectl apply`, not wrapped
in real Argo CD Applications/ApplicationSets, specifically to avoid needing a GitHub token for a
private tenant repo inside CI. `lint.yaml`/`policy.yaml` validate the ApplicationSet templates
statically; Argo CD's self-management and its management of Vault (both plain Applications, no
external tenant repo needed) are exercised for real in `e2e-kind.yaml`.

`docs/IMPLEMENTATION_PLAN.md`'s CI section additionally called for a Renovate config to open chart
bump PRs automatically. That is not yet implemented - see `renovate.json` (not present) as the
next infra improvement, tracked as an open item rather than guessed at without verifying
Renovate's current config schema against its own docs.
