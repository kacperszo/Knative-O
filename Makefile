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

agent-dev: ## Run the agent locally against current kubeconfig (no docker)
	cd agent && pip install -e . && knative-o-agent serve

agent-image: ## Build the agent container image
	docker build -t ghcr.io/kacperszo/knative-o-agent:latest agent
