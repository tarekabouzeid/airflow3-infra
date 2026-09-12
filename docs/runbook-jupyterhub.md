# JupyterHub — operating runbook

Shared JupyterHub instance for both tenants (tenant-a, tenant-b).
Hub lives in `af-work-a / namespace: jupyterhub`.
Notebook pods spawn in `af-work-a` **or** `af-work-b` depending on the user's profile choice.

## Architecture

```
 User's browser
       │
       ▼  http://localhost:9888
 ┌─────────────┐       kubeconfig (SA tokens)
 │  Hub pod    │ ─────────────────────────────►  af-work-a API server
 │  af-work-a  │ ─────────────────────────────►  af-work-b API server
 └─────────────┘
       │
       │ creates:  Namespace / SA / Pod / Service / Ingress
       ├─────────────────────────►  af-work-a / jupyter-<username>
       │                                │
       │                           ingress-nginx (contour class)
       │                           host port 9080
       │
       └─────────────────────────►  af-work-b / jupyter-<username>
                                        │
                                   ingress-nginx (contour class)
                                   host port 9081
```

**Hub → user browser redirect:** after spawn, JupyterHub redirects the user's browser
directly to the remote cluster's Ingress URL (`http://localhost:8080/user/<name>/` or
`http://localhost:8081/user/<name>/`). The hub does **not** proxy notebook traffic — the browser
talks to the notebook pod's cluster directly.

**IngressClass naming:** `jupyterhub-multicluster-kubespawner` v0.2 hardcodes
`ingressClassName: contour` in every Ingress it creates. ingress-nginx is installed with its
IngressClass registered under the name `contour` (not the default `nginx`), so those Ingresses
are processed correctly.

## First-time setup

```bash
# 0. Ensure clusters are up and Argo CD is running (scripts/10–40 already done).

# 1. Build hub image + create SA tokens + write Secrets.
make jupyterhub-setup

# 2. Sync the Argo CD Application (not auto-synced — Secrets must exist first).
make jupyterhub-sync

# 3. Verify:
make jupyterhub-status
# Hub UI: http://localhost:9888
```

The setup script (`scripts/85-jupyterhub-setup.sh`) is idempotent — re-running it rotates
SA tokens and refreshes both prerequisite Secrets:

| Secret name | Namespace | Contents |
|---|---|---|
| `jupyterhub-multicluster-kubeconfig` | `jupyterhub` / af-work-a | Combined kubeconfig with `af-work-a` and `af-work-b` contexts |
| `jupyterhub-auth-env` | `jupyterhub` / af-work-a | `password=<generated>` from Vault `secret/jupyterhub/auth` |

## Day-2 operations

| Task | Command |
|---|---|
| Check hub + nginx status | `make jupyterhub-status` |
| Tail hub logs | `make jupyterhub-logs` |
| Rotate SA tokens | `make jupyterhub-token-rotate` |
| Sync after config change | `make jupyterhub-sync` |

### Watching hub logs

```bash
kubectl --context kind-af-work-a -n jupyterhub logs deployment/hub -f
```

### Listing active notebook sessions

```bash
# Pods in af-work-a
kubectl --context kind-af-work-a get pods -A -l app=jupyterhub

# Namespaces in af-work-b (created by the spawner)
kubectl --context kind-af-work-b get ns | grep jupyter-
```

### Stopping a specific notebook

```bash
# Delete the user's namespace (spawner re-creates it on next spawn)
kubectl --context kind-af-work-a delete ns jupyter-<username>
# or:
kubectl --context kind-af-work-b delete ns jupyter-<username>
```

### Rotating the shared password

```bash
# Update in Vault:
kubectl --context kind-af-mgmt exec -n vault vault-0 -- \
  env VAULT_TOKEN=$(jq -r .root_token .local/vault-keys.json) \
  vault kv put secret/jupyterhub/auth password=<new-password>

# Re-run setup (refreshes jupyterhub-auth-env Secret + restarts hub):
make jupyterhub-token-rotate
```

### Upgrading the hub image

1. Update `JUPYTERHUB_HUB_IMAGE_TAG` and/or `MULTICLUSTER_SPAWNER_VERSION` in `versions.env`.
2. Update `hub.image.tag` and `targetRevision` in `platform/bootstrap/jupyterhub-af-work-a.yaml`.
3. Run `make jupyterhub-setup` to rebuild and push the new image.
4. Run `make jupyterhub-sync` to roll out the new hub pod.

## Port mapping quick reference

| Endpoint | URL (Docker host) | Route |
|---|---|---|
| JupyterHub login | `http://localhost:9888` | NodePort 30888 on af-work-a |
| Notebook in af-work-a | `http://localhost:9080/user/<name>/` | hostPort 80 on af-work-a node → ingress-nginx |
| Notebook in af-work-b | `http://localhost:9081/user/<name>/` | hostPort 80 on af-work-b node → ingress-nginx |

## Authentication

DummyAuthenticator is active. Any username is accepted; the shared password is stored in
Vault at `secret/jupyterhub/auth`. To change it see "Rotating the shared password" above.

> For production: replace DummyAuthenticator with OAuth (GitHub, Google) by changing
> `hub.config.JupyterHub.authenticator_class` and adding the OAuth credentials Secret.

## Kueue + governance interaction

| Scope | Kueue | Kyverno image policy |
|---|---|---|
| `jupyterhub` namespace | **not managed** (no `platform.kueue-managed` label) | **skipped** (engine-level exclusion in kyverno-af-work-a.yaml) |
| `jupyter-<username>` namespaces (notebook pods) | **not managed** (spawner creates them without the label) | **not matched** (no `platform.tenant-namespace: "true"` label) |

Notebook pods are outside Kueue's quota system by design: interactive sessions should never
be queued or preempted the way batch jobs are. Resource limits still apply through standard
Kubernetes LimitRange/ResourceQuota if an admin adds those to notebook namespaces.

## Troubleshooting

### Hub pod in CrashLoopBackOff

Check that both prerequisite Secrets exist:
```bash
kubectl --context kind-af-work-a -n jupyterhub get secret \
  jupyterhub-multicluster-kubeconfig jupyterhub-auth-env
```
If missing, re-run `make jupyterhub-setup`.

### Notebook spawn fails

Check hub logs for `kubectl` errors:
```bash
make jupyterhub-logs | grep -E "error|Error|kubectl"
```

Common causes:
- SA token expired → `make jupyterhub-token-rotate`
- Target cluster unreachable → check `kind get clusters` and Docker network
- ingress-nginx not ready in target cluster → `make jupyterhub-status`

### Browser shows "Connection refused" after spawn

1. Confirm ingress-nginx DaemonSet is Running: `make jupyterhub-status`
2. Confirm the KIND extraPortMapping is in effect:
   ```bash
   docker port af-work-a-control-plane
   # Should show: 0.0.0.0:9080 -> 80/tcp (and 9081 for af-work-b)
   ```
3. Confirm the notebook pod is Running in the remote cluster:
   ```bash
   kubectl --context kind-af-work-a get pod -n jupyter-<username>
   ```
4. Confirm the Ingress was created with `ingressClassName: contour`:
   ```bash
   kubectl --context kind-af-work-a get ingress -n jupyter-<username>
   ```
