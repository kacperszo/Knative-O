.PHONY: help preflight bootstrap teardown smoke agent-dev agent-image

help:
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-15s %s\n", $$1, $$2}'

preflight: ## Phase 0 only
	bash scripts/preflight.sh

bootstrap: ## Full install (idempotent)
	bash scripts/bootstrap.sh

teardown: ## Delete kind cluster / undo cloud install
	bash scripts/teardown.sh

smoke: ## Run the post-install checks
	bash scripts/smoke.sh

agent-debug: ## Diagnose a stuck agent rollout (describe + logs + RBAC check)
	bash scripts/agent-debug.sh

knative-restart: ## Roll the Knative control plane to pick up config-observability changes
	kubectl rollout restart -n knative-serving deployment/controller deployment/autoscaler deployment/activator deployment/webhook

scenario-1: ## Run demo scenario #1 — cold-start a Knative Service via the LLM
	bash scripts/scenarios/01-cold-start.sh

agent-dev: ## Run the agent locally against current kubeconfig (no docker)
	cd agent && pip install -e . && knative-o-agent serve

AGENT_IMAGE ?= knative-o-agent:local

agent-image: ## Build the agent container image (override AGENT_IMAGE=...)
	docker build -t $(AGENT_IMAGE) agent

agent-load: agent-image ## Build and load the agent image into the kind cluster
	kind load docker-image $(AGENT_IMAGE) --name $${CLUSTER_NAME:-knative-o}
