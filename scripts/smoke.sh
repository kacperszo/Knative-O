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
#
# We query Prometheus through the apiserver proxy so we don't depend on wget
# being present in the Prometheus container (recent kube-prometheus-stack
# uses a distroless image with no wget/curl). The Service name varies with
# chart version / fullnameOverride, so we probe a few likely label sets.
PROM_SVC=""
for sel in \
    "app.kubernetes.io/name=prometheus" \
    "app=kube-prometheus-stack-prometheus" \
    "operator.prometheus.io/name" ; do
  PROM_SVC=$(kubectl get svc -n monitoring -l "${sel}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "${PROM_SVC}" ]] && break
done
[[ -n "${PROM_SVC}" ]] || fail "no Prometheus Service found in monitoring (tried multiple label sets)"
log "  via svc ${PROM_SVC}"

# Pre-encoded PromQL: up{namespace="knative-serving"}
URL="/api/v1/namespaces/monitoring/services/${PROM_SVC}:9090/proxy/api/v1/query"
URL+="?query=up%7Bnamespace%3D%22knative-serving%22%7D"
RESP=$(kubectl get --raw "${URL}" 2>&1) || \
  fail "Prometheus API proxy failed: ${RESP}"
echo "${RESP}" | grep -q '"status":"success"' || \
  fail "unexpected Prometheus response: ${RESP}"
# Count series whose latest value == "1" (target up).
ACTIVE=$(echo "${RESP}" | grep -oE '"value":\[[^]]*"1"\]' | wc -l)
(( ACTIVE > 0 )) || \
  fail "Prometheus has no healthy targets in knative-serving (raw response: ${RESP})"
ok "  ${ACTIVE} knative-serving targets up"

info "Smoke: agent /healthz responds"
AGENT_POD="$(kubectl get pod -n mcp -l app.kubernetes.io/name=langchain-agent -o jsonpath='{.items[0].metadata.name}')"
# Same trick: use apiserver pod proxy so we don't need any in-container client.
kubectl get --raw "/api/v1/namespaces/mcp/pods/${AGENT_POD}:8080/proxy/healthz" >/dev/null \
  || fail "agent /healthz did not respond"
ok "  agent healthy"

ok "Smoke passed"
