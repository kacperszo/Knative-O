#!/usr/bin/env bash
# Phase 8 of the bootstrap; also runnable standalone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

info "Smoke: frontend URL reachable"
FRONTEND_URL="$(kubectl get ksvc -n astronomy-shop frontend -o jsonpath='{.status.url}')"
[[ -n "${FRONTEND_URL}" ]] || fail "frontend Knative Service has no URL yet"
curl -fsS --max-time 15 "${FRONTEND_URL}/" >/dev/null
ok "  ${FRONTEND_URL} → 200"

info "Smoke: Prometheus has scrape targets in astronomy-shop"
PROM_POD="$(kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')"
ACTIVE="$(kubectl exec -n monitoring "${PROM_POD}" -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=up{namespace="astronomy-shop"}' \
  | grep -o '"value"' | wc -l)"
(( ACTIVE > 0 )) || fail "Prometheus reports no targets in astronomy-shop"
ok "  ${ACTIVE} targets up"

info "Smoke: agent /healthz responds"
AGENT_POD="$(kubectl get pod -n mcp -l app.kubernetes.io/name=langchain-agent -o jsonpath='{.items[0].metadata.name}')"
kubectl exec -n mcp "${AGENT_POD}" -- \
  python -c "import urllib.request,sys;sys.exit(0 if urllib.request.urlopen('http://localhost:8080/healthz').status==200 else 1)"
ok "  agent healthy"

ok "Smoke passed"
