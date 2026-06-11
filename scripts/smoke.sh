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
# Query through the apiserver POD proxy (vs service proxy): pod proxy accepts
# port NUMBERS, service proxy requires the named port — which varies with
# chart version. Pod proxy needs no in-container wget/curl either, so it
# works with the distroless Prometheus image kube-prometheus-stack uses now.
PROM_POD=""
for sel in \
    "app.kubernetes.io/name=prometheus" \
    "app=kube-prometheus-stack-prometheus" \
    "app.kubernetes.io/managed-by=prometheus-operator" ; do
  PROM_POD=$(kubectl get pod -n monitoring -l "${sel}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "${PROM_POD}" ]] && break
done
[[ -n "${PROM_POD}" ]] || fail "no Prometheus pod found in monitoring"
log "  via pod ${PROM_POD}"

# Pre-encoded PromQL: up{namespace="knative-serving"}
URL="/api/v1/namespaces/monitoring/pods/${PROM_POD}:9090/proxy/api/v1/query"
URL+="?query=up%7Bnamespace%3D%22knative-serving%22%7D"

# Defensive `if !` everywhere — bash on macOS has well-known set -e + $(...)
# quirks; we never want a silent abort on a check that's supposed to fail loud.
RESP=""
if ! RESP=$(kubectl get --raw "${URL}" 2>&1); then
  fail "Prometheus API proxy failed: ${RESP}"
fi
if ! echo "${RESP}" | grep -q '"status":"success"'; then
  fail "unexpected Prometheus response: ${RESP}"
fi
ACTIVE=$(echo "${RESP}" | grep -oE '"value":\[[^]]*"1"\]' | wc -l | tr -d ' ')
if [[ "${ACTIVE}" == "0" ]]; then
  fail "Prometheus has no healthy targets in knative-serving (response: ${RESP})"
fi
ok "  ${ACTIVE} knative-serving targets up"

info "Smoke: agent /healthz responds"
AGENT_POD=$(kubectl get pod -n mcp -l app.kubernetes.io/name=langchain-agent \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "${AGENT_POD}" ]] || fail "no langchain-agent pod found in mcp namespace"
if ! kubectl get --raw "/api/v1/namespaces/mcp/pods/${AGENT_POD}:8080/proxy/healthz" >/dev/null 2>&1; then
  fail "agent /healthz did not respond"
fi
ok "  agent healthy"

ok "Smoke passed"
