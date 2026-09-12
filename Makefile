SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.ONESHELL:

include versions.env
export

KIND_NETWORK ?= kind
CLUSTERS := af-mgmt af-work-a af-work-b
PORT ?= 8081

.PHONY: help preflight clusters teardown-clusters local-registry \
        bootstrap install-argocd vault-init vault-configure remote-access \
        seed-tenant-secrets seed-headlamp-kubeconfigs seed-object-store status test-integration \
        upgrade-argocd ui-argocd ui-airflow ui-headlamp ui-vault ui-seaweedfs port-forward \
        port-forward-stop lint teardown images \
        governance-status governance-report governance-enforce

help:
	@echo "Common targets:"
	@echo "  make preflight          - check local tooling + docker + RAM"
	@echo "  GITHUB_TOKEN=ghp_xxx make bootstrap - clusters + registry + argocd + root app"
	@echo "                            (GITHUB_TOKEN needs read access to this platform repo,"
	@echo "                             registered as Argo CD's own repo credential)"
	@echo "  make vault-init         - initialize & unseal Vault (writes .local/vault-keys.json)"
	@echo "  make vault-configure    - configure Vault auth mounts, tenant KV, policies, roles"
	@echo "  make remote-access      - wire remote-cluster kubeconfigs into Vault per tenant"
	@echo "  make seed-headlamp-kubeconfigs - wire af-work-a/b kubeconfigs into Headlamp on af-mgmt"
	@echo "  make seed-object-store  - wire SeaweedFS S3 creds into Vault (Airflow remote task logs)"
	@echo "  make status             - show Application sync/health across all tenants"
	@echo "  make test-integration   - run the 2 integration DAGs for every tenant"
	@echo "  make port-forward       - forward Argo CD + Headlamp + Vault + SeaweedFS + both tenants' Airflow UIs to localhost"
	@echo "                            (also runs automatically at the end of bootstrap)"
	@echo "  make port-forward-stop  - stop them"
	@echo "  make upgrade-argocd VERSION=<chart-version> - bump Argo CD via GitOps"
	@echo "  make lint               - helm lint/template + kubeconform + policy checks"
	@echo "  make governance-status  - ClusterQueues/LocalQueues/Workloads + ClusterPolicy readiness, both workload clusters"
	@echo "  make governance-report  - tenant PolicyReport failures, both workload clusters (what Enforce would reject)"
	@echo "  make governance-enforce - reminder of the safe Audit -> Enforce sequence (see docs/runbook-governance.md)"
	@echo "  make teardown           - delete all 3 kind clusters"

preflight:
	bash scripts/00-preflight.sh

clusters:
	bash scripts/10-create-clusters.sh

local-registry:
	bash scripts/20-local-registry.sh

images:
	docker build -t localhost:$(LOCAL_REGISTRY_PORT)/airflow-tenant:3.1.7-hashicorp-2 \
		--build-arg AIRFLOW_VERSION=$(AIRFLOW_APP_VERSION) images/airflow
	docker push localhost:$(LOCAL_REGISTRY_PORT)/airflow-tenant:3.1.7-hashicorp-2

install-argocd:
	bash scripts/30-install-argocd.sh

bootstrap: preflight clusters local-registry images install-argocd
	bash scripts/40-register-clusters.sh
	bash scripts/45-seed-headlamp-kubeconfigs.sh
	bash scripts/95-port-forward.sh
	@echo "Bootstrap complete. Run 'make vault-init' next."

vault-init:
	bash scripts/50-vault-init.sh

vault-configure:
	bash scripts/60-vault-configure.sh

remote-access:
	bash scripts/70-remote-access.sh

seed-headlamp-kubeconfigs:
	bash scripts/45-seed-headlamp-kubeconfigs.sh

seed-object-store:
	bash scripts/65-seed-object-store.sh

seed-tenant-secrets:
	bash scripts/80-seed-tenant-secrets.sh

status:
	@for c in $(CLUSTERS); do \
		echo "== $$c =="; \
		kubectl --context kind-$$c -n argocd get applications.argoproj.io 2>/dev/null || true; \
	done

test-integration:
	bash scripts/90-run-integration-tests.sh

upgrade-argocd:
	@if [ -z "$(VERSION)" ]; then echo "usage: make upgrade-argocd VERSION=<argo-cd chart version>"; exit 1; fi
	@echo "Bump targetRevision to $(VERSION) in platform/bootstrap/app-argocd-self.yaml, commit, then sync."
	@echo "See docs/runbook-argocd-upgrade.md for the full, safe sequence."

ui-argocd:
	kubectl --context kind-af-mgmt -n argocd port-forward svc/argocd-server 8080:443

ui-headlamp:
	kubectl --context kind-af-mgmt -n headlamp port-forward svc/headlamp 8083:80

ui-vault:
	kubectl --context kind-af-mgmt -n vault port-forward svc/vault-ui 8200:8200

ui-seaweedfs:
	kubectl --context kind-af-mgmt -n seaweedfs port-forward svc/seaweedfs-filer 8888:8888

ui-airflow:
	@if [ -z "$(TENANT)" ]; then echo "usage: make ui-airflow TENANT=tenant-a [PORT=8081]"; exit 1; fi
	@home_cluster=$$(grep -A1 '^homeCluster:' platform/tenants/$(TENANT)/tenant.yaml | grep 'name:' | awk '{print $$2}'); \
	if [ -z "$$home_cluster" ]; then echo "could not find homeCluster.name in platform/tenants/$(TENANT)/tenant.yaml"; exit 1; fi; \
	echo "$(TENANT)'s home cluster is $$home_cluster, forwarding to localhost:$(PORT)"; \
	kubectl --context kind-$$home_cluster -n $(TENANT)-airflow port-forward svc/$(TENANT)-airflow-api-server $(PORT):8080

port-forward:
	bash scripts/95-port-forward.sh

port-forward-stop:
	bash scripts/95-port-forward.sh stop

lint:
	@echo "Linting charts..."
	@for c in charts/*/; do helm lint "$$c" || exit 1; done
	@echo "Rendering charts against test fixtures..."
	@helm template tenant-project charts/tenant-project -f tests/fixtures/tenant-a-project.yaml > /tmp/render-tenant-project.yaml
	@helm template airflow-tenant charts/airflow-tenant -f tests/fixtures/tenant-a-airflow.yaml > /tmp/render-airflow-tenant.yaml || true
	@yamllint -c .yamllint.yaml . || true
	@shellcheck scripts/lib/*.sh scripts/*.sh || true

teardown-clusters teardown:
	bash scripts/99-teardown.sh

# --- governance (Kueue + Kyverno) -------------------------------------------------------------
# Day-2 operation only - installing/upgrading Kueue and Kyverno themselves is GitOps
# (platform/bootstrap/kueue-*.yaml, kyverno-*.yaml), never done from here. See
# docs/runbook-governance.md for what each of these is actually checking and why.
WORKLOAD_CLUSTERS := af-work-a af-work-b

governance-status:
	@for c in $(WORKLOAD_CLUSTERS); do \
		echo "== $$c: Kueue topology =="; \
		kubectl --context kind-$$c get resourceflavor,cohort,clusterqueue,workloadpriorityclass -o wide 2>/dev/null || true; \
		echo "== $$c: ClusterPolicy readiness (kyverno) =="; \
		kubectl --context kind-$$c get clusterpolicy -o wide 2>/dev/null || true; \
		echo "== $$c: per-tenant LocalQueues + pending/admitted Workloads =="; \
		for ns in $$(kubectl --context kind-$$c get ns -l platform.kueue-managed=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do \
			echo "--- $$ns ---"; \
			kubectl --context kind-$$c -n $$ns get localqueue -o wide 2>/dev/null || true; \
			kubectl --context kind-$$c -n $$ns get workloads.kueue.x-k8s.io -o wide 2>/dev/null || true; \
		done; \
	done

governance-report:
	@echo "Rows below are what Enforce would reject right now - see docs/runbook-governance.md"
	@echo "(\"Rolling out: Audit -> Enforce\") before flipping charts/cluster-governance/values.yaml."
	@for c in $(WORKLOAD_CLUSTERS); do \
		echo "== $$c =="; \
		kubectl --context kind-$$c get policyreport -A -o json 2>/dev/null \
			| jq -r '.items[].results[]? | select(.result=="fail") | "\(.policy)/\(.rule)  \(.resources[0].namespace)/\(.resources[0].name)"' \
			| sort | uniq -c | sort -rn || true; \
	done

governance-enforce:
	@echo "1. make governance-report  - confirm it is empty on BOTH workload clusters (background scan"
	@echo "   already covers pods that are running now, not just new ones)."
	@echo "2. Run a full Airflow + Spark cycle for both tenants (make test-integration) and re-check."
	@echo "3. Set policy.action: Enforce in charts/cluster-governance/values.yaml, commit, push, let"
	@echo "   Argo CD sync cluster-governance-af-work-a/b."
	@echo "4. make governance-status  - confirm every ClusterPolicy is still Ready on both clusters."
	@echo "See docs/runbook-governance.md, \"Rolling out: Audit -> Enforce\", for the full reasoning -"
	@echo "including why this order (never Enforce first)."

