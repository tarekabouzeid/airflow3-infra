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
provisions ReadWriteOnce/ReadWriteOncePod. With it disabled, each task's logs would otherwise live
only in the pod that produced them and be lost once that pod is gone - worked around with remote
logging to SeaweedFS (see "Object storage / remote task logs" below), Airflow's own documented fix
for exactly this KubernetesExecutor gap.

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

## Object storage / remote task logs

`platform/bootstrap/seaweedfs-af-mgmt.yaml` deploys SeaweedFS on af-mgmt only - an S3-compatible
object store, reachable from af-work-a/af-work-b the same way Vault is (`service.type: NodePort`
on the af-mgmt-control-plane container, over the shared `kind` Docker network; see
`scripts/lib/common.sh`). Apache-2.0, chosen over MinIO specifically because MinIO's OSS edition is
no longer fully open-source as of its 2025 licensing change.

Its only purpose is Airflow remote task-log storage. `scripts/65-seed-object-store.sh` generates an
access/secret key pair (stored as the `seaweedfs-s3-credentials` Secret in the `seaweedfs`
namespace - never committed, it's a live key pair) and writes an `s3_logs` Airflow connection into
every tenant's Vault KV mount (`<tenant>/connections/s3_logs`, `conn_type=aws`, `extra` carrying
`endpoint_url`/`region_name` alongside the keys) - the same VaultBackend mechanism every other
Airflow connection in this repo already uses. `charts/airflow-tenant` (and
`platform/bootstrap/appset-tenant-airflow.yaml` for the real per-tenant deployments) set
`AIRFLOW__LOGGING__REMOTE_LOGGING=True` / `REMOTE_LOG_CONN_ID=s3_logs` /
`REMOTE_BASE_LOG_FOLDER=s3://<tenant>-logs/airflow-logs`, with one bucket per tenant
(`s3.createBuckets` in the SeaweedFS Application) matching that folder.

Needs `apache-airflow-providers-amazon` in the custom image (`images/airflow/Dockerfile`) for
`S3TaskHandler`/`S3Hook` - bumped the image tag to `3.1.7-hashicorp-2` alongside adding it, since
reusing the old tag would have left nodes serving a stale cached image missing the new provider.
**Sequencing matters here**: this repo's `platform/bootstrap/appset-tenant-airflow.yaml` applies
automatically (`selfHeal: true`) to every tenant, so the new `REMOTE_LOGGING` env vars reach
tenant-a/b as soon as this repo's `main` is synced - regardless of whether either tenant's own
`deploy/airflow/values.yaml` (a separate, platform-repo-inaccessible git repo) has actually adopted
image tag `3.1.7-hashicorp-2` yet. Until it has, that tenant's Airflow pods still run the old image
without `apache-airflow-providers-amazon`, and `remote_logging=True` would fail to load the S3 log
handler - each tenant repo bumping its own image tag is a required, separate follow-up, not
something this platform repo can do on a tenant's behalf.

## Remote workload execution

`scripts/70-remote-access.sh` mints a long-lived token for the `<tenant>-workload-runner`
ServiceAccount that `charts/tenant-project` already created (via GitOps) in the *remote* cluster's
`<tenant>-workloads` namespace, builds a kubeconfig, and writes it into Vault at
`<mount>/connections/k8s_remote` as a structured Kubernetes connection
(`conn_type=kubernetes`, `extra={"kube_config": ..., "in_cluster": false}`). Both
`KubernetesPodOperator` and `SparkKubernetesOperator` then reach the remote cluster with
`kubernetes_conn_id="k8s_remote"` - same Vault-backed mechanism, both operators.

## Governance (Kueue + Kyverno)

Full detail in `docs/runbook-governance.md`; the architectural shape is:

Three enforcement points, at three different times. `conftest` checks the platform's own manifests
pre-merge; the Argo CD `AppProject` restricts what GitOps may create at sync time; **Kueue and
Kyverno govern what a running tenant workload may do, at admission time**. The third was the gap:
Airflow's `KubernetesPodOperator` and the Spark Operator create pods at runtime from DAG code —
which is essentially all of a tenant's real resource consumption — long after CI and Argo CD are
out of the picture.

- **Kueue** (`kueue-af-work-{a,b}.yaml`) admits tenant batch work against quota. Per tenant per
  cluster, `charts/tenant-queue` renders a `<tenant>-high` ClusterQueue holding that tenant's
  guaranteed `nominalQuota` and a `<tenant>-low` queue with `nominalQuota: 0` that runs purely on
  capacity borrowed from idle cohort-mates and is the first thing reclaimed. Both sit in one
  `tenants` cohort. Tenants pick a lane with the `kueue.x-k8s.io/queue-name` label; how big each
  lane is comes from the platform-owned registry.
- **Kyverno** (`kyverno-af-work-{a,b}.yaml`) constrains workload shape: registry allowlist,
  per-container resource ceiling, PriorityClass allowlist, Pod Security Standards, host ports,
  node pinning, Service types. Chosen over Gatekeeper because the defaulting rules need real
  conditional mutation, and because keeping admission policy in Kyverno YAML leaves Rego meaning
  exactly one thing in this repo (`conftest`, at CI time) rather than two similar-looking dialects.
- **`charts/cluster-governance`** holds the cluster-scoped objects both depend on: four
  `PriorityClass`es, the `ResourceFlavor`, the `Cohort`, and the `ClusterPolicy` set.

### Deviation worth noting: queues are platform-owned, not tenant-owned

`appset-tenant-queues.yaml` runs under `project: default`, unlike every other tenant-facing
Application. `ClusterQueue` is cluster-scoped, and a tenant `AppProject` deliberately whitelists
nothing cluster-scoped except `Namespace` — rendering queues under the tenant's own project would
mean widening that whitelist to `ClusterQueue`, which is exactly the permission that would let a
tenant mint themselves quota. So the platform renders them, from numbers held in
`platform/tenants/*/workloads-*.yaml`.

### Sync waves

Governance forced the wave layout to grow: `1` operators (ESO, Spark Operator, Kueue, Kyverno),
`2` governance objects, `3` tenant namespaces and workloads (moved down from 2), `4` tenant queues.
Wave 2 has to precede wave 3 because Kyverno mutates a `PriorityClass` onto every tenant pod and a
pod naming a class that does not yet exist is rejected outright.

### Two priority mechanisms, each used for what it is for

Queueing priority (what Kueue admits first, and whose work the high lane preempts) is a Kueue
`WorkloadPriorityClass`, selected by the `kueue.x-k8s.io/priority-class` label and set by Kyverno
from the lane the tenant chose. Scheduling priority (kube-scheduler placement, kubelet eviction)
stays an ordinary `PriorityClass`, set in each component's own pod spec by the chart that owns it.

The original design used a single ladder for both, with Kyverno mutating the pod's own
`priorityClassName`. That is not possible: Kubernetes' built-in Priority admission plugin owns
that field, stamping the resolved integer into `spec.priority` and rejecting any pod whose integer
disagrees with its name — which is exactly what a webhook changing the name after the fact
produces. Every rendered-manifest and fixture check passed; only `governance-kind`, against a live
API server, caught it. See `docs/runbook-governance.md` for the error and the reasoning.

A tenant pod naming no `PriorityClass` therefore has pod priority 0, below `tenant-airflow` and far
below `platform-critical` — so platform components still outrank tenant work, which is the
property that has to hold.

### What is not queued, and why

A tenant's Airflow control plane (`<tenant>-airflow`) is deliberately outside Kueue's
`managedJobsNamespaceSelector`. Kueue's `deployment`/`statefulset` integrations would suspend a
scheduler or api-server pending quota, taking the tenant's whole Airflow offline rather than
delaying a task. A consequence worth stating: `KubernetesExecutor` worker pods land in that
namespace too, so Airflow's own per-task pods are not currently queued — only the
`KubernetesPodOperator` and Spark pods they launch are.

## JupyterHub — cross-cluster notebook spawning

A shared JupyterHub hub lives in `af-work-a / namespace: jupyterhub`. Both tenants share one
hub (DummyAuthenticator, shared password from Vault). Users pick a **profile** — "Cluster A" or
"Cluster B" — and the hub spawns the notebook pod in the selected cluster.

### Spawner: jupyterhub-multicluster-kubespawner

The hub uses `jupyterhub-multicluster-kubespawner v0.2` (baked into
`images/jupyterhub/Dockerfile` on top of `quay.io/jupyterhub/k8s-hub:3.3.8`) rather than the
standard KubeSpawner. The multicluster spawner invokes `kubectl --context <name>` (the `kubectl`
binary is also baked into the image) to create, in the target cluster:

1. A `Namespace` named `jupyter-<username>`
2. A `ServiceAccount` for the notebook process
3. A `Pod` running the notebook image
4. A `Service` exposing the notebook's HTTP port
5. An `Ingress` routing `http://localhost:908{0,1}/user/<username>/` to the pod

The hub then returns the Ingress URL to JupyterHub, which **redirects the user's browser** to
the remote cluster's Ingress directly. The hub does not proxy notebook traffic.

### Ingress: ingress-nginx masquerading as Contour

The spawner hardcodes `ingressClassName: contour` in every Ingress it creates. Rather than
installing Contour, `ingress-nginx` is deployed in each workload cluster with its `IngressClass`
resource registered under the name **`contour`** (not the default `nginx`), so the spawner's
Ingresses are processed by ingress-nginx without any change to the spawner code.

### PORT MAPPING (KIND)

| Endpoint | URL on Docker host | Route |
|---|---|---|
| Hub login | `http://localhost:9888` | NodePort 30888 on af-work-a (KIND extra port mapping) |
| Notebook in af-work-a | `http://localhost:9080/user/<name>/` | KIND port 9080 → node port 80 → ingress-nginx DaemonSet |
| Notebook in af-work-b | `http://localhost:9081/user/<name>/` | KIND port 9081 → node port 80 → ingress-nginx DaemonSet |

### Kubeconfig Secret

`scripts/85-jupyterhub-setup.sh` mints a long-lived `hub-spawner` ServiceAccount token in each
cluster (pattern matches `scripts/45-seed-headlamp-kubeconfigs.sh`) and stores a combined
kubeconfig as `Secret/jupyterhub-multicluster-kubeconfig` in the `jupyterhub` namespace on
af-work-a. Context names `af-work-a` / `af-work-b` in the kubeconfig match the `spawner_override`
keys in the Argo CD Application's `hub.extraConfig`.

### Governance interaction

Notebook namespaces (`jupyter-<username>`) are created dynamically by the spawner without the
`platform.tenant-namespace: "true"` label, so no ClusterPolicy in `cluster-governance` ever
matches them. The `jupyterhub` namespace is added to the Kyverno engine's
`resourceFiltersIncludeNamespaces` skip list (`kyverno-af-work-a.yaml`). Notebook pods are
entirely outside Kueue's `managedJobsNamespaceSelector` — interactive sessions are not queued or
preempted the way batch jobs are.

### First-time setup (manual before first Argo CD sync)

The Argo CD Application is `syncPolicy: {}` (no automated sync) because the hub pod mounts two
Secrets that must exist before start:

```bash
make jupyterhub-setup    # build image, mint tokens, write Secrets
make jupyterhub-sync     # argocd app sync jupyterhub-af-work-a
```

See `docs/runbook-jupyterhub.md` for day-2 operations.

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

SeaweedFS is left out of `e2e-kind.yaml` too, for a different reason: resource budget, not
topology. `ci/values-airflow-ci.yaml`'s own comments document a GitHub-hosted runner's KIND node at
only 2 CPU total, already tight enough that Airflow component CPU requests/limits needed hand
scaling down to fit - adding SeaweedFS's 4 components (master/volume/filer/s3) on top risks
breaking scheduling for the workload CI actually exists to prove. `lint.yaml`/`policy.yaml` still
cover its static manifest and chart-version pin; remote logging's real upload/retrieval path is
proven locally instead (`make seed-object-store`, see `docs/runbook-bootstrap.md`).

The tenant layer in `e2e-kind.yaml` is applied with `helm template | kubectl apply`, not wrapped
in real Argo CD Applications/ApplicationSets, specifically to avoid needing a GitHub token for a
private tenant repo inside CI. `lint.yaml`/`policy.yaml` validate the ApplicationSet templates
statically; Argo CD's self-management and its management of Vault (both plain Applications, no
external tenant repo needed) are exercised for real in `e2e-kind.yaml`.

`docs/IMPLEMENTATION_PLAN.md`'s CI section additionally called for a Renovate config to open chart
bump PRs automatically. That is not yet implemented - see `renovate.json` (not present) as the
next infra improvement, tracked as an open item rather than guessed at without verifying
Renovate's current config schema against its own docs.
