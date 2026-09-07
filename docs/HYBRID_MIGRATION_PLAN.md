# Hybrid Platform Migration Plan: VKS 9 + AWS EKS

Runbook-style plan for taking this platform off local KIND clusters and onto real infrastructure:
a **management cluster** and **one runtime environment** on VMware **vSphere Kubernetes Service
(VKS) 9** (VCF 9.x), and a **second runtime environment** on **AWS EKS**, one dedicated AWS account
per tenant. `SeaweedFS` is replaced by `MinIO` as the platform's object store. This document is the
plan; it does not change any manifest in this repo by itself. Treat it the way
`docs/IMPLEMENTATION_PLAN.md` was treated for the original build: a reference to implement against,
verifying every version/API/quota assumption against the real environment before committing to it
(Rule 0 in that document still applies here, verbatim).

## 0. Terminology, for readers new to VCF/VKS

- **VCF (VMware Cloud Foundation) 9.x** — the on-prem/private-cloud stack (vSphere + NSX + vSAN)
  this plan assumes is already licensed and capacity-planned; provisioning VCF itself is out of
  scope here.
- **vSphere Supervisor** — the built-in Kubernetes control plane VCF 9 exposes directly on top of
  vSphere (no separate management cluster to stand up by hand, unlike VCF 8/Tanzu Kubernetes Grid).
- **VKS (vSphere Kubernetes Service)** — the component that lets the Supervisor provision
  Kubernetes clusters (formerly "Tanzu Kubernetes Grid Service", now first-class in VCF 9/9.1).
  VCF 9.1 raised the ceiling to 500 clusters per Supervisor and added multi-network support for
  nodes — both matter below.
- **vSphere Namespace (Supervisor Namespace)** — a resource-quota'd, RBAC'd slice of a Supervisor,
  the vSphere-native tenancy primitive. This plan uses it once per **cluster** we provision (mgmt,
  runtime), not once per tenant — tenant isolation inside the shared VKS runtime cluster is plain
  Kubernetes `Namespace` + `ResourceQuota` + `NetworkPolicy`, exactly as this repo already does on
  KIND.
- **Account vending** — creating a fresh AWS account programmatically (via AWS Organizations,
  optionally fronted by Control Tower's Account Factory for Terraform / AFT) rather than by hand
  in the console.
- **IRSA** — IAM Roles for Service Accounts: the mechanism that lets an EKS pod assume an AWS IAM
  role via its Kubernetes ServiceAccount, without a static credential.

## 1. What "same infra" means here, and where it deliberately doesn't

The current repo's actual design — Argo CD app-of-apps + ApplicationSets, a platform-owned tenant
registry (`platform/tenants/`) as the trust boundary, per-tenant `AppProject`, Vault + ESO hybrid
secrets, remote task logging to an S3-compatible store, cross-cluster workload execution via a
`k8s_remote` Airflow connection — all survives the move unchanged in *shape*. What changes is
**everything underneath that shape that assumed a single Docker host**: cluster provisioning,
cross-cluster networking, storage classes, Vault's auth-mount-per-cluster model at multi-account
scale, and CI's single-runner topology. Section 4 maps this component-by-component.

**Tenancy model, stated once, precisely** (the user's requirement, made concrete):

| Runtime | Isolation boundary | What a tenant gets |
|---|---|---|
| VKS shared runtime | Kubernetes `Namespace` (+ `ResourceQuota` + `NetworkPolicy` + `AppProject`) inside **one** shared VKS guest cluster | `<tenant>-airflow` and `<tenant>-workloads` namespaces, same as today |
| AWS EKS | **AWS account** (org unit under a dedicated OU), each with its own VPC and its own EKS cluster | A whole account: its own EKS cluster, its own IAM, its own VPC/subnets, its own KMS keys |

The EKS side is a materially stronger isolation boundary than anything in the current repo (account
boundary vs. namespace boundary), which changes the IaC and the onboarding runbook more than it
changes the GitOps layer — Argo CD still just needs a cluster's API endpoint and a credential to
sync into, same as `scripts/40-register-clusters.sh` does today; getting that endpoint and
credential to exist per tenant is the new work.

## 2. Target topology

```
                              ┌────────────────────────────────────────────┐
                              │   VCF 9.x private cloud (one Supervisor,    │
                              │   or two if capacity/blast-radius demands   │
                              │   splitting mgmt from runtime - see 3.1)    │
                              │                                             │
  ┌───────────────────────┐   │  ┌─ vks-mgmt (VKS guest cluster) ───────┐  │
  │  Tenant AWS account A │   │  │ Argo CD (self-managed, hub)          │  │
  │  ┌─ EKS cluster ────┐ │   │  │ Vault (HA, Raft, AWS-KMS auto-unseal)│  │
  │  │ tenant-a-airflow │◀┼───┼──┤ MinIO Operator + Tenant (buckets)    │  │
  │  │ tenant-a-workloads│ │   │  │ Headlamp (optional, ops UI)          │  │
  │  └──────────────────┘ │   │  └───────────────────────────────────────┘  │
  │  own VPC/IAM/KMS      │   │                    │ registers               │
  └───────────────────────┘   │                    ▼                        │
            ▲                 │  ┌─ vks-runtime (shared VKS guest cluster)┐ │
            │ cross-account    │  │ tenant-b-airflow / tenant-b-workloads  │ │
  ┌───────────────────────┐   │  │ tenant-c-airflow / tenant-c-workloads  │ │
  │  Tenant AWS account B │   │  │ ... one namespace pair per VKS tenant  │ │
  │  ┌─ EKS cluster ────┐ │   │  │ Spark Operator, ESO (shared install)   │ │
  │  │ tenant-d-airflow │◀┼───┼──┴─────────────────────────────────────────┘ │
  │  │ tenant-d-workloads│ │   │                                             │
  │  └──────────────────┘ │   └────────────────── Direct Connect / VPN ─────┘
  └───────────────────────┘                              │
                                              ┌───────────▼───────────┐
                                              │  AWS "network hub"    │
                                              │  account: Transit GW, │
                                              │  DX gateway, Vault's  │
                                              │  AWS-auth trust anchor│
                                              └────────────────────────┘
```

Argo CD, Vault, and MinIO stay centralized on `vks-mgmt`, exactly as af-mgmt is today. Every
EKS tenant cluster and the shared `vks-runtime` cluster register into that one Argo CD, exactly as
af-work-a/af-work-b register today (`scripts/40-register-clusters.sh`'s pattern, extended — see
6.3).

### 2.1 One Supervisor or two?

VCF 9.1's Supervisor scales to 500 clusters and multi-network per cluster, so `vks-mgmt` and
`vks-runtime` can both be guest clusters on the **same** Supervisor if there is one shared VCF
environment. Split into two Supervisors (or two vCenter/NSX domains) only if there's an existing
organizational reason to isolate the management plane's blast radius from tenant workload capacity
(e.g. separate upgrade cadences, separate change-control windows, or the mgmt cluster needing
guaranteed capacity independent of whatever tenants schedule on `vks-runtime`). Default
recommendation: **one Supervisor**, two guest clusters (`vks-mgmt`, `vks-runtime`), each its own
vSphere Namespace with its own resource pool — simplest to operate, matches the "test in a real
environment" framing, and nothing in the plan below depends on splitting them.

## 3. Component-by-component mapping (current KIND lab → target)

| Component | Today (KIND) | Target | Notes |
|---|---|---|---|
| Cluster provisioning | `kind create cluster` (`scripts/10-create-clusters.sh`) | Terraform: `TanzuKubernetesCluster` CR (VKS) / `aws_eks_cluster` (EKS) | See §5 |
| Cross-cluster addressing | Docker container-name DNS on the `kind` network | VKS↔VKS: routable NSX/Supervisor network, real DNS. VKS↔EKS: Direct Connect/VPN + Transit Gateway, real DNS/private hosted zones | See §6 |
| Container registry | `kind-registry:5001` (local, unauthenticated) | Per-environment private registry: Harbor (or VCF's built-in image registry service) for VKS, Amazon ECR (one per tenant account, or a shared ECR in a hub account with cross-account pull policies) for EKS | Image builds move to a real CI pipeline (§9) |
| Storage class (DAGs PVC, Postgres) | `local-path` (RWO, single-node) | VKS: vSAN-backed `Datastore` StorageClass (`vsphere-csi`, RWO is fine, no single-node constraint since vSAN isn't node-local). EKS: `gp3` via the `ebs-csi-driver` (RWO) | The single-node RWO constraint that shaped this repo's whole "must stay one node" design goes away entirely — see 4.1 |
| Argo CD | `helm install` once, then self-managed | Same self-managed pattern, running on `vks-mgmt` | Multi-source Applications, ApplicationSets, `charts/tenant-project` AppProject model: **unchanged** |
| Vault | OSS, standalone, file storage, one pod | OSS or Enterprise, **HA with Raft storage**, 3-5 replicas, **auto-unseal via AWS KMS** (reachable over the same hub-account connectivity used for everything else) | See §7 |
| External Secrets Operator | One install per workload cluster | One install per workload cluster (`vks-runtime`, and one per tenant EKS cluster) | Unchanged pattern, more installs |
| Object storage | SeaweedFS (Apache-2.0), single Application on af-mgmt | **MinIO** (Operator + `Tenant` CR), on `vks-mgmt` | See §8. Note this plan does **not** revisit SeaweedFS-vs-MinIO licensing reasoning from `versions.env` — the user has already decided MinIO for the target platform |
| Spark Operator | One Helm install per workload cluster, `spark.jobNamespaces` hardcoded per tenant | One install per workload cluster (`vks-runtime`, each tenant EKS cluster) | Same `deletecollection` RBAC fix from this session (§4.2) must ship in the base `charts/tenant-project` RBAC template used everywhere |
| Tenant registry / trust boundary | `platform/tenants/<tenant>/*.yaml`, git file generator | **Same file shape**, but each file also needs a `runtime: vks \| eks` discriminator and (for `eks`) an `awsAccountId`/`clusterRegion` — see §10 | This is the one schema change to the existing GitOps layer |
| CI | `.github/workflows/e2e-kind.yaml`, one KIND cluster on the runner | Real, persistent staging environments (one VKS namespace, one EKS "ci" account) exercised from GitHub Actions via OIDC federation, no more local clusters | See §9 |

### 4.1 The single-node constraint disappears — but don't remove the guardrails that depended on it

`docs/architecture.md` is explicit that every KIND cluster is single-node *because* `local-path`
is RWO and every Airflow component (including ephemeral KubernetesExecutor pods) mounts the same
DAGs PVC. On real infrastructure:

- VKS: `vsphere-csi` volumes backed by vSAN are not node-local — RWO still means "one writer", but
  any node in the guest cluster can mount it, so multi-node node pools are safe.
- EKS: `gp3` via `ebs-csi-driver` is an AZ-scoped EBS volume — still RWO, and still "any node in
  that AZ", so pin the DAGs-PVC-mounting pods' node pool to a single AZ (or move to EFS via
  `efs-csi-driver` for genuine multi-AZ RWX, at higher latency/cost) rather than assuming it's
  simply solved.

Do **not** treat "we're on real infra now" as license to drop the `dagLoader` git-clone-to-PVC
pattern in favor of something fancier (git-sync sidecars, `dags.gitSync.enabled`) as part of this
migration — that's an orthogonal improvement with its own risk, and every fix from this session
(deterministic naming, RBAC, quota sizing) was validated against the current PVC-based DAG delivery
model. Change one variable at a time.

### 4.2 Fixes from this session that must ship as day-1 defaults, not follow-ups

These were real, validated bugs found and fixed against the KIND lab this session. They are not
KIND-specific — they reproduce identically on VKS and EKS, and should never be rediscovered there:

| Bug | Fix | Where it must land |
|---|---|---|
| `tenant-workload-runner` Role granted `delete` but not `deletecollection` on pods/configmaps, and no rule at all for services/PVCs — Spark's own driver-side cleanup 403'd, and the Kubeflow Spark Operator surfaced a **successfully completed** job as `FAILED` | Grant `deletecollection` + add `services`/`persistentvolumeclaims` rules | Already fixed in `charts/tenant-project/templates/rbac.yaml` (commit `7029a6a` on this repo) — **verify it's still there**, don't re-derive it |
| `SparkKubernetesOperator`'s default `random_name_suffix=True` + `delete_on_termination=True` + a DAG-parse-time `uuid.uuid4()` for the app name meant `submit_*` and `wait_*` tasks (separate pods, separate Python processes) disagreed on the SparkApplication's name almost every run | `random_name_suffix=False`, `delete_on_termination=False`, name derived from Airflow's `run_id` (sanitized for DNS-1123), **not** `ts_nodash`/`ds`/`ts` — those are only injected into the Jinja context `if dag_run.logical_date`, which is `None` for a `schedule=None` DAG's manual trigger in Airflow 3 | Already fixed in both tenant repos' `dags/it_spark.py` and `dags/spark/spark_pi.yaml`, and in `ci/dags/it_spark.py` in this repo. **Any new tenant DAG that submits a `SparkApplication` must copy this pattern**, not the naive `uuid`/`ts_nodash` one — call this out explicitly in `docs/runbook-tenant-onboarding.md` |
| `tenant-*-quota`'s `limits.cpu: "12"` left ~1 CPU of true headroom once concurrent task pods + hook Jobs overlapped, causing an intermittent, hard-to-reproduce `exceeded quota` 403 on pod creation that looked like a flaky test, not a sizing bug | Bumped to 16 in this repo (`charts/tenant-project/values.yaml`) | Do **not** just copy `16` to real infra unmodified — see §4.3, quotas need to be re-derived from real node/pool sizes, not kept as a KIND-era magic number |
| Argo CD's `selfHeal: true` fighting a cosmetic diff (a StatefulSet field the API server back-fills) causes **perpetual, unrelated resyncs** that roll every Deployment in the affected Application every few minutes — this repeatedly and non-deterministically starved CPU quota and broke in-flight task pods during this session's own testing | A targeted `ignoreDifferences` entry on the affected Application, found by diffing `helm template` output against the live object, not guessed | Already fixed for Vault's own chart in this repo (`platform/bootstrap/vault-af-mgmt.yaml`). **Run the same diff-and-fix exercise against every chart used on `vks-mgmt`/`vks-runtime`/EKS before enabling `selfHeal: true` in the real environment** — this class of bug is chart-version-specific and will very likely recur with different charts/versions on real infra |
| `scripts/65-seed-object-store.sh` (bucket + credentials + Vault connection seeding) is idempotent but has to be **remembered and manually run** — it was not, for over 44 hours, and that's the actual incident this whole investigation started from | Make the equivalent step in the real environment **not a script a human has to remember** — see §8.3 (MinIO provisioning as a reconciled Kubernetes resource, not an imperative script) | New requirement for this plan, not a copy of an existing fix |
| A platform-wide feature flag (`AIRFLOW__LOGGING__REMOTE_LOGGING=True`, pushed via `appset-tenant-airflow.yaml`'s `selfHeal: true`) reached every tenant the moment the platform repo merged, regardless of whether that tenant's own image tag had the required provider yet | None applied this session (documented as a known caveat, not fixed) | This plan's Phase 5 (§11.5) adds an explicit compatibility gate before any such platform-wide env var change ships in the hybrid environment — see there |

### 4.3 Quota sizing must be re-derived, not copied

The `12`→`16` CPU bump in this session was sized against a documented, measured steady-state
(9 containers × 1 CPU LimitRange default) on a specific KIND-era `LimitRange`. On real infra:

1. Measure the real steady-state footprint of one tenant's Airflow (`kubectl describe resourcequota`
   after a fresh, idle deployment) on the actual VKS/EKS node types chosen.
2. Set `limitRange.defaultLimitCPU`/`defaultLimitMemory` deliberately, not left at the KIND-era
   `1`/`1Gi` — real Spark drivers/executors and real DAG workloads will want more than 1 CPU by
   default in many cases; a LimitRange this tight will silently throttle every pod that doesn't set
   explicit `resources`.
3. Set `quota.limits.cpu`/`limits.memory` to steady-state + (max concurrent task pods a tenant is
   contracted for) × (their real per-pod limit) + one hook-Job's worth of margin, and **document
   the arithmetic in the values file comment**, the way `charts/tenant-project/values.yaml`
   already does — that comment is what let this session diagnose the bug quickly; don't lose it.
4. Prefer **cluster/node-pool autoscaling** (VKS node pool autoscaling; EKS Managed Node Groups
   or Karpenter) so the quota is a governance ceiling, not the thing standing between a tenant and
   real capacity that exists but isn't scheduled yet.

## 5. IaC layout

Add a new top-level directory to this repo, `iac/`, alongside `platform/` and `charts/` (GitOps
stays GitOps; IaC is what has to exist *before* GitOps can reach anything). Structure:

```
iac/
  aws/
    modules/
      account-vending/     # AWS Organizations account create + baseline (SCPs, CloudTrail, Config)
      network-hub/         # Transit Gateway, DX Gateway attachment, hub VPC
      eks-tenant/          # per-tenant: VPC, EKS cluster, node groups, IRSA roles, ECR (optional)
    envs/
      hub/                 # one apply: the network-hub + AWS Organization root config
      tenants/
        tenant-b/           # one apply per EKS tenant: instantiates eks-tenant module
        tenant-d/
  vsphere/
    modules/
      vks-cluster/          # vSphere Namespace + TanzuKubernetesCluster CR (via kubectl/helm
                             # provider against the Supervisor API - VKS clusters are k8s objects,
                             # not vSphere provider-native resources)
    envs/
      vks-mgmt/
      vks-runtime/
  backend.tf                # shared remote-state config (see below)
```

**State backend**: one S3 bucket + DynamoDB lock table in a dedicated, minimal-blast-radius AWS
"tooling" account (create this one account by hand, once — bootstrapping Terraform state storage
with Terraform is the well-known chicken-and-egg problem, don't fight it). Every root module above,
including the `vsphere/` ones, uses this same S3 backend with a distinct `key` per environment
(`vsphere/vks-mgmt/terraform.tfstate`, `aws/tenants/tenant-b/terraform.tfstate`, etc.) — one state
backend for the whole hybrid estate, regardless of which cloud a given root module targets.

**Why `kubectl`/`helm` Terraform providers for VKS, not a vSphere-native Terraform resource**: VKS
guest clusters are Kubernetes custom resources (`TanzuKubernetesCluster`, or in VCF 9's supervisor
services model, whatever the current CRD name is — **verify this against
`https://techdocs.broadcom.com/.../vsphere-kubernetes-service` for the installed VCF 9.x patch
before writing any module**, the CRD/API group has changed across VCF/Tanzu generations and this
plan's knowledge cutoff cannot be treated as current). Terraform's `vsphere` provider manages the
underlying vSphere objects (resource pools, networks) if those aren't already provisioned by
platform/infra teams separately; the guest cluster itself is created by applying that CRD to the
Supervisor's API server, which Terraform's `kubernetes`/`helm` providers (pointed at the Supervisor
context) do natively.

**Order of operations** (this is what makes it a runbook, not just a diagram — see §11 for the full
phased version with verification steps):

1. `iac/aws/envs/hub` → network hub account: Transit Gateway, DX Gateway (or a Site-to-Site VPN if
   DX isn't provisioned yet — see §6.2), Terraform state bucket already exists from the manual
   bootstrap step above.
2. `iac/vsphere/envs/vks-mgmt` → the management VKS cluster.
3. Install Argo CD on `vks-mgmt` (still one imperative `helm install` + one `kubectl apply`, exactly
   as `scripts/30-install-argocd.sh` does today — this one step stays imperative deliberately,
   same reasoning as the original plan: it's what lets GitOps take over everything after it).
4. `iac/vsphere/envs/vks-runtime` → the shared runtime cluster; register it into Argo CD.
5. Per new EKS tenant: `iac/aws/envs/tenants/<tenant>` (account vending + EKS + IRSA), then register
   the resulting cluster into Argo CD, then commit that tenant's `platform/tenants/<tenant>/*.yaml`.

## 6. Networking

### 6.1 VKS mgmt ↔ VKS runtime

Same VCF estate (§2.1) — this is a routed NSX overlay/Supervisor network problem, not a
hybrid-cloud problem. Confirm with VCF 9.1's multi-network support that `vks-mgmt` and
`vks-runtime` guest clusters can reach each other's Kubernetes API and any `NodePort`/`LoadBalancer`
Services (Vault, MinIO) by routable IP or a private DNS zone — this replaces the "shared `kind`
Docker network + container-name DNS" trick from `scripts/lib/common.sh` one-for-one. **Do not**
carry over NodePort-based addressing (`af-mgmt-control-plane:30820` style) if VCF's NSX Advanced
Load Balancer (Avi) or an equivalent is available — use a real internal `LoadBalancer` Service +
private DNS record for Vault and MinIO instead; NodePort addressing was a KIND-specific workaround
for not having a real load balancer, not a design goal.

### 6.2 VKS mgmt ↔ AWS EKS tenants

This is the genuinely new problem the KIND lab never had to solve (its "remote cluster" was always
the same Docker host). Two viable paths, pick based on what connectivity already exists:

- **Production-grade**: AWS Direct Connect from the VCF site to an AWS "network hub" account,
  terminating on a Direct Connect Gateway, associated with a Transit Gateway in the hub account.
  Each tenant EKS account's VPC attaches to that Transit Gateway (via Resource Access Manager
  share, since it's cross-account). Vault, MinIO, and Argo CD's cluster-registration traffic all
  ride this path. This is the right long-term answer and the one to build toward.
- **Fast path for "test in a real environment" now**: a Site-to-Site VPN from the VCF site's edge
  (NSX-T VPN gateway) to the same hub-account Transit Gateway, which every tenant account still
  peers with via RAM. Functionally identical topology to Direct Connect, lower throughput/higher
  latency, provisionable in hours instead of weeks. **Recommended starting point for this plan** —
  swap the VPN attachment for a DX attachment later without touching anything downstream (Vault
  configs, Argo CD cluster registrations, MinIO endpoints all reference the Transit Gateway's
  routes, not the VPN/DX distinction).

Either way, do not expose Vault's or MinIO's API publicly to make this "simpler" — that trades a
real networking task for a real security regression. If genuinely no VPN/DX can be stood up before
testing needs to start, the minimum acceptable interim is: public endpoints behind a strict IP
allowlist (the tenant EKS VPCs' NAT gateway egress IPs) **plus** mTLS in front of Vault
(`listener "tcp" { tls_... }` with client-cert verification) and MinIO's own IAM policies scoped
per tenant — treat this explicitly as an interim state to retire once the VPN/DX exists, not the
final design.

### 6.3 Argo CD cluster registration at multi-account scale

`scripts/40-register-clusters.sh` today mints a long-lived bearer token for an `argocd-manager`
ServiceAccount per workload cluster and stores it as an Argo CD cluster Secret — this pattern is
fine for `vks-runtime` (still one cluster to register) but does not scale cleanly to "one new AWS
account per tenant": a static long-lived token per tenant account is a real secret-sprawl and
rotation problem the moment there are more than a handful of tenants.

Recommended replacement for the EKS side only: register each tenant cluster into Argo CD using
`awsAuthConfig` in the cluster Secret (Argo CD's native EKS support), backed by a cross-account IAM
role in each tenant account (`arn:aws:iam::<tenant-account-id>:role/argocd-cluster-access`) that
trusts the mgmt account's Argo CD IRSA role. Argo CD then calls `sts:AssumeRole` + `eks:GetToken`
per sync, no static credential stored at all. This requires Argo CD itself to run with an IRSA-style
identity even though its home cluster is VKS, not EKS — practically, that means either (a) running
a small EKS-hosted "Argo CD repo-server/application-controller" component just for AWS auth
brokering, or (b) using a long-lived-but-narrowly-scoped IAM user credential stored in Vault and
injected via the cluster Secret's `execProviderConfig`, refreshed by a small sidecar/cronjob that
calls `aws eks get-token` and updates the Secret. **Verify which of these Argo CD's installed
version actually supports before committing** — `execProviderConfig` support and its exact shape
has changed across Argo CD major versions, and this repo is already mid-upgrade-rehearsal (2.14 →
3.x) per `docs/runbook-argocd-upgrade.md`; confirm behavior on whatever version lands there.

## 7. Secrets: Vault at hybrid, multi-account scale

Vault's current design (`docs/architecture.md`) — one Kubernetes-auth mount per cluster
(`kubernetes-work-a`, `kubernetes-work-b`), each backed by a `vault-token-reviewer` ServiceAccount
in that cluster — assumes Vault can reach every cluster's TokenReview API directly, and that the
number of clusters is small and platform-managed. Neither holds for "one AWS account per tenant":

- **VKS side (`vks-runtime`)**: keep Kubernetes auth exactly as today — one mount
  (`kubernetes-vks-runtime`), same pattern, same `scripts/60-vault-configure.sh`-style idempotent
  configuration (or its Terraform equivalent via `terraform-provider-vault`, recommended for the
  real environment — the original plan already flagged this as "the production path" and deferred
  it for the lab; this migration is exactly the point to pick it up).
- **EKS side**: switch to Vault's **AWS auth method** (IAM auth), not Kubernetes auth. A pod
  authenticates to Vault by presenting a signed `sts:GetCallerIdentity` request via its IRSA-issued
  AWS credentials; Vault validates it against AWS STS directly (only needs internet/DX reachability
  to `sts.amazonaws.com`, never needs to reach into each tenant's EKS API server). One Vault AWS
  auth role per tenant, bound to that tenant's specific IAM role ARN
  (`bound_iam_principal_arn=arn:aws:iam::<tenant-account>:role/tenant-airflow-irsa`) — this scales
  to arbitrarily many tenant accounts without adding a Vault auth mount per account, unlike the
  Kubernetes-auth pattern.
- Keep the **KV-v2-mount-per-tenant** and **policy-per-role** structure unchanged either way —
  `tenant-<x>/connections/*`, `variables/*`, `db`, `git`, `workload-secrets`, exactly as today.
  Only the *auth method* differs by runtime, not the secrets layout, so `charts/airflow-tenant`'s
  `AIRFLOW__SECRETS__BACKEND_KWARGS` only needs `auth_type` (and its AWS-specific fields) to differ
  per tenant's `runtime`, not a deeper restructuring.
- **Auto-unseal**: move off Shamir-shares-in-a-gitignored-JSON-file (fine for a laptop lab, not
  fine for real infra) to **auto-unseal via AWS KMS**, using a KMS key in the hub account, reachable
  over the same VPN/DX path already built for everything else. Document the break-glass recovery
  key procedure (`vault operator generate-root`) explicitly in the runbook (§11.1) — auto-unseal
  removes the *daily* operational burden, not the need for a documented disaster-recovery path.
- **HA**: Raft integrated storage, 3 or 5 replicas, on `vks-mgmt`. This is a real behavior change
  from "one standalone pod with file storage" and needs its own smoke test (kill the leader pod,
  confirm a follower takes over, confirm ESO/Airflow reconnect without manual intervention) before
  any tenant traffic depends on it — add this explicitly to the Phase 1 exit criteria (§11.1).

## 8. Object storage: MinIO

### 8.1 Deployment

Replace `platform/bootstrap/seaweedfs-af-mgmt.yaml` with a MinIO Operator install
(`platform/bootstrap/minio-operator-vks-mgmt.yaml`, a plain Argo CD Application, same static
app-of-apps tier as Vault/Headlamp today — object storage doesn't multiply per tenant the way
Airflow does, so it doesn't need an ApplicationSet) plus one MinIO `Tenant` custom resource
(`platform/bootstrap/minio-tenant-vks-mgmt.yaml`) sized for the real environment (start at 4 drives
across 4 nodes for erasure-coded resilience — MinIO's own guidance, not a KIND-era single-pod
shortcut like SeaweedFS's single-node deployment was).

### 8.2 Multi-tenant bucket/policy model

Keep the existing one-bucket-per-tenant convention (`tenant-a-logs`, `tenant-b-logs`, ...,
matching `AIRFLOW__LOGGING__REMOTE_BASE_LOG_FOLDER=s3://<tenant>-logs/airflow-logs`) rather than
one shared bucket with prefixes — it's a straightforward MinIO IAM policy per tenant
(`s3:*` scoped to `arn:aws:s3:::<tenant>-logs/*`) and keeps the blast radius of a leaked credential
to one tenant's logs, matching the account-per-tenant EKS isolation philosophy even on the shared
VKS side.

### 8.3 Provisioning must not repeat the `scripts/65-seed-object-store.sh` incident

The actual incident this whole session started from was a manual, easy-to-forget script step
(bucket + credentials + Vault connection wiring) that silently never ran. On real infra, **don't
carry the imperative-script pattern forward for this specific step** — reconcile it declaratively
instead:

- Use the **MinIO Operator's own `Tenant`/`PolicyBinding`/bucket-provisioning CRDs** (or the
  `minio/operator` Terraform provider, if reconciling via Terraform+Atlantis/similar is preferred
  over a CRD) so bucket existence is a **desired-state object Argo CD watches and self-heals**,
  not a script's side effect.
- For the *credentials → Vault* wiring specifically (MinIO access/secret key pair written into
  every tenant's `<tenant>/connections/s3_logs` KV path), replace the imperative
  `scripts/65-seed-object-store.sh` with a small **Kubernetes Job triggered as an Argo CD
  `PostSync` hook** on the MinIO Tenant Application (same hook mechanism this repo already uses for
  the tenant `dag-loader` Job) — this makes it re-run automatically every time the MinIO Application
  syncs, instead of depending on a human remembering a separate `make` target. Generate the
  key pair once and store it as a Kubernetes Secret (or in Vault directly) so re-runs are
  idempotent, exactly like the current script's own reuse-if-exists logic — just triggered by
  GitOps, not by memory.
- Add a **synthetic health check** (an Argo CD `Application` health check, or a scheduled DAG in a
  dedicated "platform" Airflow tenant) that writes and reads back a canary object in each tenant's
  bucket and alerts if it fails — this is the guardrail that would have caught this session's
  44-hour outage in minutes instead of via manual investigation.

### 8.4 Reachability from EKS tenants

MinIO lives on `vks-mgmt`; EKS tenant pods reach it over the same VPN/DX path from §6.2. Watch
upload latency for remote task logs specifically — if it becomes a bottleneck for EKS tenants
(cross-cloud round-trip per log flush), MinIO's active-active multi-site replication is the
documented scale-out path: a second MinIO deployment in the AWS hub account, replicating from the
`vks-mgmt` instance, with each EKS tenant's `s3_logs` connection pointed at the nearer replica.
Treat this as a fast-follow, not a day-1 requirement — don't build it before there's a measured
latency problem to justify it.

## 9. CI/CD adaptation

`.github/workflows/e2e-kind.yaml` today stands up one throwaway KIND cluster per run because there
was no persistent real infrastructure to test against. That constraint is gone; replace it with
persistent staging environments, not more ephemeral clusters:

- **VKS side**: a persistent `ci`-tenant namespace pair (`ci-airflow`, `ci-workloads`) on
  `vks-runtime`, torn down and recreated *at the namespace level* per CI run (cheap — no new
  cluster, no new node pool) via the same `helm template | kubectl apply` pattern
  `e2e-kind.yaml` uses today for the tenant layer (bypassing real Argo CD Applications in CI
  remains the right call, for the same "no tenant repo credential needed in CI" reason already
  documented in `docs/architecture.md`).
- **EKS side**: **do not** vend a fresh AWS account per CI run — account vending is a multi-minute,
  rate-limited AWS Organizations operation, wrong latency for CI. Instead: one persistent "ci"
  tenant AWS account (vended once, like a real tenant, via §5's Terraform), with a **persistent**
  EKS cluster in it, and ephemeral **namespaces** per CI run, same as the VKS side. This also
  means CI is exercising the *real* AWS-IAM-auth Vault path and the *real* cross-account Argo CD
  registration path (§6.3, §7) on every run, not a simulated stand-in — a strictly better test than
  today's single-cluster `k8s_remote`-points-at-itself simulation.
- GitHub Actions authenticates to AWS via **OIDC federation** (no long-lived AWS credentials in
  repo secrets) — a dedicated IAM role in the "ci" tenant account, trust-policy-scoped to this
  repo's OIDC subject claim.
- Runner resource constraints (the documented 2-CPU GitHub-hosted runner limit that forced
  SeaweedFS out of `e2e-kind.yaml` and Airflow's own resources to be hand-scaled down) **disappear**
  once CI targets real clusters instead of a KIND cluster running on the runner itself — the runner
  now only needs enough CPU/memory to run `kubectl`/`terraform`/`helm`, not the workload itself.
  This means the real e2e suite can (and should) cover MinIO, Spark Operator, and both integration
  DAGs (`it_kubernetes_pod_operator`, `it_spark`) in every run, on every runtime, unlike today's
  reduced CI profile.

## 10. Tenant registry schema change

Add exactly two fields to `platform/tenants/<tenant>/tenant.yaml` to disambiguate runtime:

```yaml
tenant: tenant-d
runtime: eks                 # "vks" | "eks" - new field
awsAccountId: "123456789012" # required when runtime: eks; used to derive the cross-account
                              # IAM role ARN for Argo CD cluster registration (§6.3) and the
                              # Vault AWS-auth bound_iam_principal_arn (§7)
platformRepoURL: https://github.com/tarekabouzeid/airflow3-infra
tenantRepoURL: https://github.com/tarekabouzeid/airflow3-infra-tenant-d
tenantRepoBranch: main
homeCluster:
  name: eks-tenant-d          # or "vks-runtime" for a VKS tenant
  server: https://<eks-endpoint>   # populated after iac/aws/envs/tenants/tenant-d apply
  vaultAuthMountPath: aws-tenant-d # or "kubernetes-vks-runtime" for a VKS tenant
vault:
  mountPoint: tenant-d
  airflowRole: tenant-d-airflow
  esoRole: tenant-d-eso
```

`appset-tenant-airflow.yaml`/`appset-tenant-workloads.yaml` templates gain a `{{ if eq .runtime
"eks" }}...{{ else }}...{{ end }}` branch wherever the Vault `auth_type`/`BACKEND_KWARGS` differ
(§7) — everything else in those ApplicationSet templates (the multi-source Application shape, the
`charts/airflow-tenant` wiring, the tenant-repo `ref: values` source) is runtime-agnostic and
**must stay that way**; resist the temptation to fork the template per runtime, the whole point of
this repo's existing design is that onboarding is "add one file", not "pick the right template".

## 11. Phased rollout runbook

Each phase has explicit exit criteria — do not start the next phase until the current one's
criteria are met and written down (an incident log, not just tribal memory: this session's own
44-hour SeaweedFS outage and the multi-hour Spark debugging chain both happened because small
assumptions went unverified past the point they should have blocked progress).

### Phase 0 — Foundations (no clusters yet)

1. Confirm VCF 9.x capacity plan for two guest clusters' worth of compute (`vks-mgmt` sized for
   Argo CD + Vault HA + MinIO's erasure-coded drives; `vks-runtime` sized for however many VKS
   tenants are planned in year 1, plus headroom per §4.3).
2. Create the AWS "tooling" account by hand (Terraform state bucket + DynamoDB lock table) and the
   AWS "network hub" account (via Organizations, can be Terraform-managed once the tooling account
   exists to hold its state).
3. Stand up the VPN (or DX, if already available) between the VCF site and the hub account's
   Transit Gateway (§6.2). **Exit criterion**: a `ping`/`curl` from a VM or jump host on the VCF
   side reaches an EC2 instance's private IP in the hub VPC, and vice versa.
4. Provision DNS: a private hosted zone (or equivalent) resolvable from both sides for
   `vault.platform.internal`, `minio.platform.internal`, etc. — replaces
   `af-mgmt-control-plane`-style Docker DNS.
5. Write `iac/` module skeletons (§5) against the verified VKS API surface (**mandatory
   verification step, not optional**: `kubectl api-resources | grep -i tanzu` or equivalent against
   a real VCF 9.x Supervisor before writing the `vks-cluster` module, since the exact CRD group/
   version is VCF-patch-dependent and this plan's own knowledge of it may already be stale).

### Phase 1 — Management cluster (`vks-mgmt`)

1. `iac/vsphere/envs/vks-mgmt` apply → guest cluster exists, `kubectl` reaches it.
2. Install Argo CD (imperative, once — §5 step 3), apply the root Application.
3. Deploy Vault HA + Raft + AWS KMS auto-unseal. **Exit criteria**: `vault operator raft
   list-peers` shows all replicas; kill the current leader pod, confirm a follower is elected and
   ESO/Airflow (once they exist, later phases) reconnect without a manual `vault-unseal` step.
4. Deploy MinIO Operator + Tenant. **Exit criteria**: create a test bucket, write/read/delete an
   object through both the internal (VKS) and cross-account (once §Phase 3/4 connectivity exists)
   paths.
5. Run the `helm template`-vs-live-object diff exercise (§4.2's Argo CD churn lesson) against
   every chart deployed so far, add `ignoreDifferences` proactively. **Exit criterion**: every
   Application on `vks-mgmt` reaches `Synced`/`Healthy` and *stays* there for 24 hours with
   `selfHeal: true` on, with zero unexplained pod restarts (`kubectl get events
   --field-selector reason=Killing` empty across that window).

### Phase 2 — VKS shared runtime + first VKS tenant

1. `iac/vsphere/envs/vks-runtime` apply, register into Argo CD.
2. Install ESO + Spark Operator on `vks-runtime`.
3. Onboard one real (or pilot) tenant end-to-end using the **existing**
   `docs/runbook-tenant-onboarding.md` steps, with `runtime: vks` in its registry entry.
4. Run both integration DAGs (`it_kubernetes_pod_operator`, `it_spark`) to a clean, repeatable green
   state — apply the exact verification loop this session used (trigger, poll `airflow tasks
   states-for-dag-run`, confirm no `deletecollection`/naming/quota symptoms recur) before declaring
   this phase done. **Exit criterion**: 3 consecutive clean runs, not 1 — this session's own Spark
   fix needed multiple attempts to separate real bugs from transient quota/resync noise, and a
   single green run is not enough evidence on infrastructure this new.

### Phase 3 — AWS foundation + first EKS tenant

1. `iac/aws/envs/tenants/<first-tenant>` apply: account vending, VPC, EKS cluster, IRSA roles.
2. Register the new EKS cluster into Argo CD via the cross-account IAM path (§6.3).
3. Configure Vault's AWS auth method + a role scoped to this tenant's IRSA role ARN (§7).
4. Onboard the tenant's Airflow deployment (same GitOps mechanics as VKS, different
   `runtime`/`vault.authMountPath` per §10).
5. Same integration-test exit criterion as Phase 2 (3 consecutive clean runs), now exercising real
   cross-account, cross-cloud connectivity for the first time.

### Phase 4 — Second EKS tenant + connectivity hardening

1. Repeat Phase 3's steps for a second tenant account, specifically to prove the account-vending
   and cross-account IAM patterns are actually repeatable (not hand-tuned for the first tenant).
2. If Phase 0 started on VPN, evaluate cutting over to Direct Connect now that there's real traffic
   to size it against.
3. Load-test MinIO's cross-cloud reachability under both EKS tenants' concurrent log-write traffic;
   decide whether §8.4's multi-site replication fast-follow is now justified.

### Phase 5 — Platform-wide change safety (closing the SeaweedFS-caveat gap)

Encode, as an actual CI check (`conftest`/OPA policy, extending `tests/policy/main.rego`), the
compatibility gate this session's SeaweedFS work admittedly lacked: before
`appset-tenant-airflow.yaml` (or its equivalent) can set a new platform-wide Airflow env var that
depends on a provider package, the policy must verify every currently-registered tenant's declared
image tag/digest actually contains that provider — either by maintaining a small manifest
(`platform/tenants/<tenant>/image-capabilities.yaml`, platform-owned, updated when a tenant bumps
their image) or by having CI actually pull each tenant's image manifest and inspect installed
packages. Block the merge, don't just document the caveat, if any registered tenant would break.

### Phase 6 — Cutover / parity validation checklist

Before calling the hybrid environment "the platform" (vs. "a parallel environment being proven
out"):

- [ ] Every fix in §4.2's table verified present and re-tested on **both** VKS and EKS, not just
      wherever it was first noticed.
- [ ] Vault HA failover tested under load, not just at idle.
- [ ] MinIO erasure-coding tested by actually losing a drive/node in a non-prod MinIO Tenant and
      confirming no data loss and no manual intervention needed.
- [ ] Argo CD cluster-registration credential rotation tested for at least one EKS tenant (prove
      the cross-account IAM role trust policy survives a role ARN or external-ID rotation without
      manual Secret editing).
- [ ] CI's persistent staging environments (§9) have run the full integration suite green at least
      10 times consecutively, across both runtimes, with no manual intervention.
- [ ] A documented, tested disaster-recovery runbook exists for: Vault unseal-key/KMS-key loss,
      losing the `vks-mgmt` cluster entirely (can Argo CD + Vault + MinIO be rebuilt from `iac/` +
      git alone?), and losing one tenant's EKS account (does it affect any other tenant? it must
      not, by construction — prove it, don't assume it).
- [ ] The imperative-script inventory (`scripts/*.sh` equivalents in the new environment) is
      reviewed for the same class of "easy to forget" risk that caused this session's SeaweedFS
      incident, and anything imperative that *can* be made a reconciled/declarative step (§8.3's
      pattern) has been.

## 12. Open items / explicitly deferred

- **VKS API/CRD verification**: this plan references `TanzuKubernetesCluster`-shaped resources by
  the name most recently known for this concept; VCF 9.x may have renamed or restructured this
  (the search conducted while writing this plan found VCF 9.1 material but not the exact current
  CRD schema) — **verify against `techdocs.broadcom.com`'s current VCF 9.x vSphere Kubernetes
  Service docs before writing `iac/vsphere/modules/vks-cluster`**, exactly as `IMPLEMENTATION_PLAN.md`'s
  Rule 0 required for every Helm chart version in the original build.
- **Renovate / automated chart-bump PRs**: still an open item from the original plan
  (`docs/architecture.md`'s own closing note), unresolved here too — pick it up once the hybrid
  environment has more than one chart-version pin to keep current across three runtimes instead of
  one.
- **MinIO multi-site replication**: deliberately deferred to a measured need (§8.4), not built
  speculatively.
- **Per-tenant EKS cost allocation / showback**: account-per-tenant makes AWS Cost Explorer's
  account-level breakdown free; this plan does not design a chargeback process, only notes the
  primitive that makes one easy to build later.
