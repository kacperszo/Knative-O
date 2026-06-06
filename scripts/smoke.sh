#!/usr/bin/env bash
# Phase 8 of the bootstrap; also runnable standalone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

info "Smoke: frontend Deployment is Available"
kubectl wait -n astronomy-shop deploy/frontend --for=condition=Available --timeout=60s
ok "  frontend Available"

info "Smoke: frontend-proxy Service has ready endpoints"
EPS="$(kubectl get endpoints -n astronomy-shop frontend-proxy \
  -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)"
(( EPS > 0 )) || fail "frontend-proxy has no ready endpoints"
ok "  frontend-proxy endpoints: ${EPS}"

info "Smoke: Prometheus is scraping the Knative control plane"
# We assert on knative-serving rather than astronomy-shop: the app runs as
# plain Deployments until the agent converts a service, so our queue-proxy
# PodMonitor matches nothing yet. Knative control-plane targets prove our
# monitoring pipeline works.
PROM_POD="$(kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')"
ACTIVE="$(kubectl exec -n monitoring "${PROM_POD}" -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=up{namespace="knative-serving"}==1' \
  | grep -o '"value"' | wc -l)"
(( ACTIVE > 0 )) || fail "Prometheus reports no healthy targets in knative-serving"
ok "  ${ACTIVE} knative-serving targets up"

info "Smoke: agent /healthz responds"
AGENT_POD="$(kubectl get pod -n mcp -l app.kubernetes.io/name=langchain-agent -o jsonpath='{.items[0].metadata.name}')"
kubectl exec -n mcp "${AGENT_POD}" -- \
  python -c "import urllib.request,sys;sys.exit(0 if urllib.request.urlopen('http://localhost:8080/healthz').status==200 else 1)"
ok "  agent healthy"

ok "Smoke passed"
