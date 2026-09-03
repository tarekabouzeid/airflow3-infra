SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.ONESHELL:

include versions.env
export

KIND_NETWORK ?= kind
CLUSTERS := af-mgmt af-work-a af-work-b

.PHONY: help preflight clusters teardown-clusters local-registry \
        bootstrap install-argocd vault-init vault-configure remote-access \
        seed-tenant-secrets status test-integration upgrade-argocd \
        ui-argocd ui-airflow lint teardown images

help:
	@echo "Common targets:"
	@echo "  make preflight          - check local tooling + docker + RAM"
	@echo "  make bootstrap          - clusters + registry + argocd(old) + root app"
	@echo "  make vault-init         - initialize & unseal Vault (writes .local/vault-keys.json)"
	@echo "  make vault-configure    - configure Vault auth mounts, tenant KV, policies, roles"
	@echo "  make remote-access      - wire remote-cluster kubeconfigs into Vault per tenant"
	@echo "  make status             - show Application sync/health across all tenants"
	@echo "  make test-integration   - run the 2 integration DAGs for every tenant"
	@echo "  make upgrade-argocd VERSION=<chart-version> - bump Argo CD via GitOps"
	@echo "  make lint               - helm lint/template + kubeconform + policy checks"
	@echo "  make teardown           - delete all 3 kind clusters"

preflight:
	bash scripts/00-preflight.sh

clusters:
	bash scripts/10-create-clusters.sh

local-registry:
	bash scripts/20-local-registry.sh

images:
	docker build -t localhost:$(LOCAL_REGISTRY_PORT)/airflow-tenant:3.1.7-hashicorp-1 \
		--build-arg AIRFLOW_VERSION=$(AIRFLOW_APP_VERSION) images/airflow
	docker push localhost:$(LOCAL_REGISTRY_PORT)/airflow-tenant:3.1.7-hashicorp-1

install-argocd:
	bash scripts/30-install-argocd.sh

bootstrap: preflight clusters local-registry images install-argocd
	bash scripts/40-register-clusters.sh
	@echo "Bootstrap complete. Run 'make vault-init' next."

vault-init:
	bash scripts/50-vault-init.sh

vault-configure:
	bash scripts/60-vault-configure.sh

remote-access:
	bash scripts/70-remote-access.sh

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

ui-airflow:
	@if [ -z "$(TENANT)" ]; then echo "usage: make ui-airflow TENANT=tenant-a"; exit 1; fi
	kubectl --context kind-af-work-a -n $(TENANT)-airflow port-forward svc/$(TENANT)-airflow-api-server 8081:8080

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
