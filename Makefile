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

grafana: ## Port-forward our Grafana (monitoring/prom-grafana) to localhost:3000
	@echo "Grafana → http://localhost:3000  (admin / your GRAFANA_ADMIN_PASSWORD)"
	kubectl -n monitoring port-forward svc/prom-grafana 3000:80

dashboards: ## Install/refresh the Knative-O Grafana dashboards
	bash scripts/install-dashboards.sh

shop: ## Port-forward the Astronomy Shop frontend-proxy to localhost:8081
	@echo "Shop → http://localhost:8081  (Envoy /grafana/ inside the shop is disabled)"
	kubectl -n astronomy-shop port-forward svc/frontend-proxy 8081:8080

scenario-1: ## Cold-start a Knative Service via the LLM (§3.3 #1)
	bash scripts/scenarios/01-cold-start.sh
scenario-2: ## Canary traffic split 90/10 (§3.3 #2)
	bash scripts/scenarios/02-canary.sh
scenario-3: ## Autoscaling tune (§3.3 #3)
	bash scripts/scenarios/03-autoscaling.sh
scenario-4: ## Scale-to-zero proof (§3.3 #4)
	bash scripts/scenarios/04-scale-to-zero.sh
scenario-5: ## Diagnosis: agent finds why a service is failing (§3.3 #5)
	bash scripts/scenarios/05-diagnosis.sh
scenario-6: ## Rollback to previous revision (§3.3 #6)
	bash scripts/scenarios/06-rollback.sh
scenario-7: ## Reactive autoscale via Alertmanager → agent (§3.3 #7)
	bash scripts/scenarios/07-reactive.sh

agent-dev: ## Run the agent locally against current kubeconfig (no docker)
	cd agent && pip install -e . && knative-o-agent serve

AGENT_IMAGE ?= knative-o-agent:local

agent-image: ## Build the agent container image (override AGENT_IMAGE=...)
	docker build -t $(AGENT_IMAGE) agent

agent-load: agent-image ## Build and load the agent image into the kind cluster
	kind load docker-image $(AGENT_IMAGE) --name $${CLUSTER_NAME:-knative-o}
