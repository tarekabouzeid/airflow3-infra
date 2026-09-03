# Runbook: bootstrap the full local lab

Prerequisites: Docker with >= 12GiB RAM allocated, and `docker`, `kind`, `helm`, `kubectl`, `jq`,
`vault` (the CLI is only used indirectly by scripts via `kubectl exec`, but is listed by
`00-preflight.sh` for completeness) on your PATH. A GitHub personal access token with read access
to `airflow3-infra-tenant-a` and `airflow3-infra-tenant-b`.

```bash
make preflight
make bootstrap          # creates 3 kind clusters, local registry, builds+pushes the airflow
                         # image, installs Argo CD, registers af-work-a/b, applies the root app
```

After `make bootstrap`, watch Argo CD sync everything else:

```bash
export ARGOCD_PW=$(kubectl --context kind-af-mgmt -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)
make ui-argocd    # port-forwards to https://localhost:8080, login admin / $ARGOCD_PW
make status       # or watch the UI: argocd, vault, external-secrets-*, spark-operator-* should
                   # all reach Synced/Healthy within a few minutes
```

Vault comes up sealed and unconfigured - Argo CD deploying the Vault chart is not the same as
Vault being ready to serve secrets:

```bash
make vault-init        # initializes + unseals Vault, writes .local/vault-keys.json (gitignored)
make vault-configure    # kubernetes auth mounts, KV mounts, policies, roles for both tenants
GITHUB_TOKEN=ghp_xxx make seed-tenant-secrets   # git deploy token + demo variables/workload secrets
```

Once Vault is configured, the tenant Applications (which were failing health checks until now,
since their SecretStores couldn't authenticate) will self-heal to Healthy on their own - Argo CD's
`selfHeal: true` means you do not need to manually resync anything.

```bash
make remote-access      # wires each tenant's "k8s_remote" Airflow connection into Vault
make status             # everything should now read Synced / Healthy
make test-integration   # triggers both DAGs for both tenants, polls to completion
```

Tear down with `make teardown` (deletes all 3 clusters + the local registry container; Vault
keys under `.local/` are left on disk - remove manually if you want a truly clean slate).

## What to expect to go wrong the first time

See `docs/troubleshooting.md`. In particular: Argo CD Applications for a tenant will sit
`Progressing`/`Degraded` until `make vault-configure` has run (SecretStores can't authenticate
before then) - that is expected, not a bug.
