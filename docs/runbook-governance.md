# Runbook: multi-tenant governance (Kueue + Kyverno)

Two components, one job: make sure a tenant can only consume the capacity it has been given, and
can only run workloads the platform considers acceptable.

- **Kueue 0.19.4** — quota admission and queueing. Decides *whether and when* a tenant workload
  is allowed to start.
- **Kyverno 1.19.1** — admission policy (mutate + validate). Decides *what shape* a tenant
  workload is allowed to have.

Both run on every workload cluster (`af-work-a`, `af-work-b`). Neither runs on `af-mgmt` — nothing
there is tenant-facing.

## Why this layer exists at all

The platform already had two enforcement points before this one:

| Point | When it runs | What it governs |
|---|---|---|
| `conftest` / OPA (`tests/policy`) | Pre-merge, in CI | The platform's own manifests |
| Argo CD `AppProject` | Sync time | What GitOps is allowed to create, and where |
| **Kueue + Kyverno** | **Admission time** | **What a running tenant workload may do** |

The gap the third row fills: Airflow's `KubernetesPodOperator` and the Spark Operator create pods
*at runtime*, from DAG code, long after CI and Argo CD are out of the picture. Those pods are
essentially all of a tenant's actual resource consumption, and until now nothing inspected them.
A tenant could request 40 CPU, pull an arbitrary image, or name `system-cluster-critical`, and the
only thing standing in the way was a namespace `ResourceQuota` that caps totals rather than shapes.

## Why Kyverno rather than Gatekeeper

Both were considered. Kyverno won on two points specific to this platform:

1. **Real mutation.** Defaulting a `PriorityClass` per namespace role, and deriving it from the
   queue lane a tenant chose, needs conditional mutation. Gatekeeper's `Assign`/`AssignMetadata`
   can set fields but cannot express "set this to X when that label is Y, otherwise Z" without
   contortions, so the logic would have migrated into Helm templates where it is unenforceable.
2. **One meaning for Rego.** This repo already uses Rego, for `conftest` at CI time. Adding
   Gatekeeper would put a second, similar-looking-but-incompatible Rego dialect
   (`ConstraintTemplate` + `violation`) in the tree next to it. Keeping admission policy in
   Kyverno YAML means Rego means exactly one thing here.

The honest costs: Kyverno is a heavier install (three controllers rather than one), and it puts a
mutating webhook in the path of every tenant pod creation. Kubernetes 1.32's built-in
`ValidatingAdmissionPolicy` would handle the pure-validation rules with no extra component at all,
but `MutatingAdmissionPolicy` is still alpha there — and since the mutation forces a webhook
regardless, splitting the rules across two engines buys nothing.

## Priority: two mechanisms, each used for what it is for

There are two priority concepts in play and they are easy to conflate:

- A Kubernetes **`PriorityClass`** drives kube-scheduler preemption and kubelet eviction order.
- A Kueue **`WorkloadPriorityClass`** drives queue ordering and preemption *inside* Kueue.

The original design here used only the first, on the theory that one ladder honoured by both
systems cannot disagree with itself. **That does not work, and it is worth knowing why**, because
it looks correct right up until it reaches a real cluster.

`spec.priorityClassName` cannot be set by an admission webhook. Kubernetes' built-in Priority
admission plugin owns that field: it resolves the class name to an integer, stamps it into
`spec.priority`, and rejects any pod whose integer disagrees with its name. A webhook that changes
the name after the integer is stamped creates exactly that disagreement:

```
pods "admitted-task" is forbidden: the integer value of priority (0) must not be provided in
pod spec; priority admission controller computed 1000 from the given PriorityClass name
```

Every fixture test passed before this surfaced, because the Kyverno CLI does not run Kubernetes'
built-in admission chain. Only `governance-kind`, against a live API server, showed it.

So the two mechanisms are now used for what each is actually for:

- **Queueing priority** — which of a tenant's workloads Kueue admits first, and whose work the
  high lane preempts when it reclaims quota — is a **`WorkloadPriorityClass`**, selected by the
  `kueue.x-k8s.io/priority-class` **label**. Labels have no built-in plugin defending them, so the
  platform sets it from the lane the tenant chose. Tenants still set exactly one field.
- **Scheduling priority** — who the kube-scheduler places first and who the kubelet evicts under
  node pressure — stays a **`PriorityClass`**, set in each component's own pod spec by the chart
  that owns it. Nothing mutates it onto a tenant pod.

A tenant pod that names no `PriorityClass` gets pod priority 0, which is below `tenant-airflow`
and far below `platform-critical` — so platform components still outrank tenant work, which is the
property that actually has to hold. The allowlist rule bounds what a tenant *may* name; it no
longer requires them to name anything.

| Class | Value | Who gets it | How |
|---|---:|---|---|
| `platform-critical` | 1000000 | Argo CD, Vault, ESO, Spark Operator, Kueue, Kyverno | its own chart values |
| `tenant-airflow` | 100000 | A tenant's Airflow control plane | its own chart values |
| `tenant-workload-high` / `-low` | 1000 / 100 | A tenant workload that names one explicitly | opt-in, bounded by the allowlist |

And the Kueue side, set automatically from the lane:

| WorkloadPriorityClass | Value | Assigned to |
|---|---:|---|
| `tenant-high` | 10000 | workloads labelled `kueue.x-k8s.io/queue-name: high` |
| `tenant-low` | 100 | everything else in a tenant workload namespace |

The old PriorityClass ladder, for reference:

| Class | Value | Who gets it |
|---|---:|---|
| `platform-critical` | 1000000 | Argo CD, Vault, ESO, Spark Operator, Kueue, Kyverno |
| `tenant-airflow` | 100000 | A tenant's Airflow control plane — scheduler, dag-processor, api-server, triggerer, metadata DB |
| `tenant-workload-high` | 1000 | Tenant batch work in the guaranteed lane |
| `tenant-workload-low` | 100 | Tenant batch work in the opportunistic lane (`preemptionPolicy: Never`) |

None is `globalDefault`. A cluster-wide default cannot tell a tenant's scheduler from a tenant's
Spark executor, and getting that backwards means a batch task outranking the scheduler that
launched it.

`tenant-workload-low` sets `preemptionPolicy: Never`: a low-priority pod may be preempted, but
must never itself trigger an eviction. Without it, a large enough burst of low-priority pods could
still displace other work simply by being numerous.

## Queues: what "high" and "low" actually mean

Per tenant per cluster, `charts/tenant-queue` renders two `ClusterQueue`s in a shared cohort
(`tenants`), plus the `LocalQueue`s tenants reference:

- **`<tenant>-high`** holds the tenant's `nominalQuota` — its **guaranteed** share, theirs whether
  or not anyone else is busy. `reclaimWithinCohort: Any` lets it take back capacity a cohort-mate
  borrowed above that mate's own nominal quota. It may itself borrow up to `borrowingLimit`.
- **`<tenant>-low`** holds `nominalQuota: 0` and no borrowing limit. It owns nothing; it runs
  entirely on capacity its cohort-mates are not currently using, and gives it back the moment they
  want it. `reclaimWithinCohort: Never` and `withinClusterQueue: Never` mean it can never cause
  anything else to be evicted — it is the thing that gets evicted.

That asymmetry is the whole point. "Low priority" here is not a hint that gets ignored under load;
it is a structurally different claim on capacity.

Three `LocalQueue`s exist in each `<tenant>-workloads` namespace: `high`, `low`, and `default`
(pointing at the low lane). The third exists only for its name — Kueue's `LocalQueueDefaulting`
assigns any workload with no queue label to the `LocalQueue` literally called `default`.

## What is and is not queued

**Queued:** everything in `<tenant>-workloads`. Kueue runs with
`manageJobsWithoutQueueName: true`, scoped by `managedJobsNamespaceSelector` to namespaces
carrying `platform.kueue-managed: "true"` — a label `charts/tenant-project` stamps only on
workload namespaces. A tenant cannot dodge quota by simply not asking to be queued.

**Not queued:** `<tenant>-airflow`. A tenant's scheduler, dag-processor, api-server and triggerer
are long-running Deployments, and Kueue's `deployment`/`statefulset` integrations would suspend
them pending quota — taking the tenant's whole Airflow offline rather than delaying a task. They
are governed by `ResourceQuota` and `PriorityClass` instead.

**A known consequence:** `KubernetesExecutor` worker pods land in `<tenant>-airflow`, not
`<tenant>-workloads`, so Airflow's own per-task pods are *not* currently queued — only the
`KubernetesPodOperator` and Spark pods they launch are. Moving them under Kueue is a deliberate
future step: it needs the executor's namespace overridden and careful handling of preemption,
since Kueue deleting a worker pod surfaces to Airflow as a failed task.

## Gang scheduling (cluster-wide, not a tenant knob)

Two mechanisms, neither of which a tenant can turn off:

1. **Kueue admits a Workload all-or-nothing.** For a `SparkApplication`, Kueue's
   `SparkApplicationIntegration` (alpha, enabled by feature gate) sets `spec.suspend: true` on
   admission and only clears it once the driver *and every executor* fit at once. A Spark job
   never half-starts with a driver holding capacity its executors are still queueing for.
2. **`waitForPodsReady`** (timeout 15m, `blockAdmission: true`) is the second half: if the
   admitted pods do not all become ready inside the timeout, the whole Workload is evicted and
   requeued rather than left half-running holding quota. `blockAdmission` admits workloads one at
   a time, which is what prevents two multi-pod jobs each holding half the capacity the other
   needs.

`SparkApplication` integration does **not** support Spark dynamic allocation — Kueue's webhook
rejects a `SparkApplication` with `spec.dynamicAllocation.enabled: true`.

## The policy rules

All live in `charts/cluster-governance/templates/policies/`, all scoped by namespace selector to
tenant namespaces, all currently `failureAction: Audit`.

| Policy | Rejects |
|---|---|
| `tenant-restrict-image-registries` | Images outside the allowlist; images with no tag or a `:latest` tag |
| `tenant-container-resource-bounds` | A container missing CPU/memory requests or limits, or exceeding the per-container ceiling (4 CPU / 8Gi) |
| `tenant-scheduling-bounds` | A `PriorityClass` outside the tenant set (when one is named at all); `spec.nodeName`; control-plane tolerations; host ports |
| `tenant-pod-security` | Violations of the `restricted` Pod Security Standard, minus Seccomp/Capabilities for the platform's own images |
| `tenant-restrict-service-types` | `NodePort` and `LoadBalancer` Services |
| `tenant-default-queue-priority` | *(mutate)* Sets the `kueue.x-k8s.io/priority-class` label from the queue lane |

The per-container ceiling is a different question from the namespace `ResourceQuota`. A quota caps
a tenant's *total*; one pod asking for the entire quota satisfies it perfectly while starving every
other task the same tenant is running. The ceiling is what keeps a quota divisible.

### Pod Security: two layers, deliberately

`charts/tenant-project` also stamps every tenant namespace with
`pod-security.kubernetes.io/enforce: baseline`, applied natively by the API server with no webhook
involved. That is the floor that survives Kyverno being down. The tighter `restricted` standard
rides on Kyverno, where it gets PolicyReports, an Audit phase, and per-control exclusions.

`enforce` is `baseline` rather than `restricted` because `restricted` additionally demands
`seccompProfile` and an explicit drop of `ALL` capabilities on every container, which neither the
upstream Airflow chart nor the `apache/spark` images set. Enforcing that at the namespace level
would reject platform-supplied workloads with no way to grant an exception.

## Rolling out: Audit → Enforce

The chart ships `policy.action: Audit`. Under Audit every rule is evaluated and recorded in the
namespace's `PolicyReport`, and nothing is rejected.

```bash
# What would be rejected today, cluster-wide:
kubectl get policyreport -A -o json \
  | jq -r '.items[].results[] | select(.result=="fail") | "\(.policy)/\(.rule)  \(.resources[0].namespace)/\(.resources[0].name)"' \
  | sort | uniq -c | sort -rn
```

Background scanning is on, so this reports on pods that are **already running**, not only on the
next one created. When that list is empty across a full Airflow + Spark run on both clusters, flip
one value in `charts/cluster-governance/values.yaml`:

```yaml
policy:
  action: Enforce
```

Commit, let Argo CD sync. Rolling out the other way round risks a rule with a blind spot bricking
every tenant namespace on the first sync, with Argo CD dutifully re-applying it.

> A rule that reports nothing is not necessarily a rule that passes. A `ClusterPolicy` Kyverno
> refuses to load produces an *empty* PolicyReport, which reads exactly like compliance. That is
> what `tests/kyverno/run.py` exists to catch — it fails on any policy Kyverno reports as
> `Invalid Policy`, which `kyverno test` alone counts as a pass.

## Operational notes

**Kueue is a hard dependency for tenant task execution.** The pod webhooks are
`failurePolicy: Fail` inside selected namespaces, so if the Kueue controller is down, pod creation
in `<tenant>-workloads` fails rather than proceeding unqueued. That is fail-closed by design — an
unqueued pod is an unaccounted pod — but it is worth knowing before debugging a stuck DAG. Tenant
Airflow control planes are unaffected: their namespaces do not match the selector.

**Kueue does not recreate preempted pods.** For plain pod groups it sends deletes and leaves
replacement to whatever created them. For an Airflow task that means the task fails and Airflow
retries it per the DAG's own `retries` setting — so low-lane work should have retries configured.

**Kueue quota and `ResourceQuota` must not fight.** They police capacity independently: Kueue
admits against its own accounting, then the API server applies the `ResourceQuota`. If the quota
were the tighter of the two, Kueue would admit work the API server immediately rejects — pods
Pending on "exceeded quota" while `kubectl get workloads` reports them admitted. The invariant is
`kueue.nominal + kueue.borrowingLimit <= namespace ResourceQuota requests`, asserted in CI by
`tests/check_quota_invariant.py`.

**Webhook CA bundles are in `ignoreDifferences`.** Both controllers inject their own caBundle
after the webhook configurations are created; without those entries Argo CD's selfHeal reverts the
CA on the next reconcile and takes admission control down. Kyverno additionally rewrites webhook
rules under `autoUpdateWebhooks`, so those are ignored too.

## Common changes

**Allow a new image registry** — `charts/cluster-governance/values.yaml`,
`policy.images.allowed`. Add both the bare and `docker.io/`-prefixed spelling for Docker Hub
images. Platform-owned on purpose: it is the list of binaries allowed to run with tenant
credentials inside the cluster.

**Resize a tenant's lane** — `platform/tenants/<tenant>/workloads-<cluster>.yaml`, the `kueue`
block. Re-run `python3 tests/check_quota_invariant.py`; if the ceiling now exceeds the namespace
quota, raise the inline `quota` in `platform/bootstrap/appset-tenant-workloads.yaml` too.

**Raise the per-container ceiling** — `policy.resources.maxContainer`. Consider whether the
workload genuinely needs one large container or is better split.

## Verifying

```bash
# Policy logic, against fixtures - no cluster needed
python3 tests/kyverno/run.py

# Rendered objects against the real upstream CRD schemas
python3 tests/validate_against_crds.py '<crd-glob>' /tmp/render-governance.yaml

# The Kueue/ResourceQuota invariant
python3 tests/check_quota_invariant.py
```

`.github/workflows/governance-kind.yaml` does all of this against a real KIND cluster with real
Kueue and real Kyverno, and additionally proves that an unapproved image is rejected by the API
server, that a compliant pod gets a `Workload` and runs, and that a pod over its queue's quota
stays held at Kueue's scheduling gate.

## Troubleshooting

| Symptom | Look at |
|---|---|
| Pod stuck `Pending` with a `kueue.x-k8s.io/admission` scheduling gate | It is queued and waiting for quota. `kubectl -n <ns> get workloads -o wide`, then `kubectl describe clusterqueue <tenant>-<lane>` for current usage. |
| Pod rejected with a policy message | Working as intended — the message names the rule. If it is wrong, fix the rule in `charts/cluster-governance`, not the workload. |
| Pod creation fails with a webhook timeout in `<tenant>-workloads` | Kueue or Kyverno is down. `kubectl -n kueue-system get pods`, `kubectl -n kyverno get pods`. Fail-closed is intentional. |
| `LocalQueue` shows no `ClusterQueue` | The `ClusterQueue` is missing or inactive — usually a `ResourceFlavor` name mismatch. `kubectl get clusterqueue -o wide`. |
| Borrowing is not happening | Check `spec.cohortName` is set (v1beta2 renamed it from `spec.cohort`; the old spelling is silently ignored, leaving the queue in a cohort of one). |
| A `SparkApplication` never unsuspends | Driver + executors do not fit in the lane's quota. Check the `Workload`'s conditions, and that `spec.dynamicAllocation.enabled` is not set. |
