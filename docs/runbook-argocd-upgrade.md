# Runbook: Argo CD upgrade rehearsal (v2.14.x -> v3.0.x -> latest 3.x)

This is the actual point of pinning an old Argo CD version in `versions.env`: practice the
upgrade before you ever need to do it against something that matters. `.github/workflows/
argocd-upgrade.yaml` rehearses the same hops nightly on a throwaway single-cluster CI cluster -
read its output first if you want to see what to expect before doing this against the real lab.

## Before you start

- Re-resolve versions against the real registry - do not trust the values already in
  `versions.env` blindly:
  ```bash
  helm repo update argo
  helm search repo argo/argo-cd --versions | head -20
  ```
- Read the real upstream upgrade notes for the hop you're about to make:
  `https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/2.14-3.0/` (and the
  `3.0-3.1`, `3.1-3.2`, ... pages for later hops). Known 2.14 -> 3.0 breaking changes:
  fine-grained RBAC policies no longer apply to sub-resources, and logs RBAC is enforced by
  default (the logs tab needs an explicit `logs, get` grant unless your `argocd-rbac-cm` already
  sets `policy.default: role:readonly` or `role:admin`).

## The upgrade itself is one line, in git

```bash
# platform/bootstrap/app-argocd-self.yaml
spec:
  sources:
    - repoURL: https://argoproj.github.io/argo-helm
      chart: argo-cd
      targetRevision: "8.3.7"   # <- bump this
```

Commit, push, and either wait for `selfHeal` or force it:

```bash
kubectl --context kind-af-mgmt -n argocd get application argocd -w
```

Expect a brief `Progressing` or even `Unknown` health status partway through - the
application-controller restarts itself as part of its own upgrade. That is expected, not a
failure. Give it a few minutes before concluding something is actually wrong.

## After every hop

```bash
make status   # every Application, every tenant, should return to Synced/Healthy
make test-integration   # both integration DAGs, both tenants, should still pass
```

If a tenant Application goes unhealthy after an Argo CD upgrade and stays that way for more than
a couple of minutes, check for an ApplicationSet templating break first - `goTemplate: true` is
set from the start specifically to avoid the fasttemplate default flip, but if a *future* Argo CD
release changes goTemplate's own default behavior, `platform/bootstrap/appset-*.yaml` is where to
look.

## The rehearsal path

1. **v2.14.x -> v3.0.x** - the only hop with a documented *major*-version breaking-change list.
   Do this one deliberately slowly, reading the upgrade guide first.
2. **v3.0.x -> latest 3.x** - repeat the same commit-bump-watch sequence for each subsequent minor
   (`3.0-3.1`, `3.1-3.2`, ...), or jump straight to the latest 3.x chart version in one hop once
   you're comfortable with the mechanism - Argo CD's own release process supports upgrading
   across multiple minor versions at once within the same major line.

Roll back the same way: set `targetRevision` back to the previous value, commit, let selfHeal
apply it. There is no separate rollback mechanism to learn - it is the same GitOps action in
reverse.
