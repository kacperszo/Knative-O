#!/usr/bin/env bash
# Scenario 1 — Cold-start deployment via the LLM (§3.3 #1).
# Asks the agent to deploy a Knative Service that wraps the same image as
# the existing Astronomy Shop `currency` Deployment, under a DIFFERENT name
# (`currency-knative`). The original Deployment and Service stay running —
# we don't want to break the shop's checkout flow (currency is called by
# ad, cart, checkout, frontend on :8080; Knative cluster-local Services
# answer on :80, so name-replacing currency would break callers).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

NS_APP=astronomy-shop
NS_AGENT=mcp
SOURCE=currency
TARGET=${KNATIVE_TARGET:-currency-knative}

info "Scenario 1: cold-start ${TARGET} (wrapping ${SOURCE}'s image)"

IMAGE=$(kubectl get deploy -n "${NS_APP}" "${SOURCE}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
[[ -n "${IMAGE}" ]] || fail "Could not read image for Deployment/${SOURCE}; is the app installed?"
log "  source image: ${IMAGE}"

PROMPT=$(cat <<EOF
Create a new Knative Service named \`${TARGET}\` in namespace \`${NS_APP}\`
to demonstrate scale-to-zero. Use the same image as the existing
\`${SOURCE}\` Deployment.

DO NOT touch the existing \`${SOURCE}\` Deployment or its Service — they
must keep running so the rest of the Astronomy Shop continues to work.
Just create the Knative Service alongside.

Manifest to apply (apiVersion: serving.knative.dev/v1, kind: Service):
- name: ${TARGET}, namespace: ${NS_APP}
- annotations on .spec.template.metadata:
    autoscaling.knative.dev/min-scale: "0"
    autoscaling.knative.dev/max-scale: "5"
    autoscaling.knative.dev/target: "100"
    autoscaling.knative.dev/metric: "concurrency"
- containerConcurrency: 100
- timeoutSeconds: 30
- single container:
    name: currency
    image: ${IMAGE}
    ports:
      - containerPort: 8080
    env:
      - name: CURRENCY_PORT
        value: "8080"
      - name: OTEL_SERVICE_NAME
        value: ${TARGET}
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: http://otel-collector:4317

Echo the YAML you plan to apply, then apply it. Use the
\`resources_create_or_update\` tool.
EOF
)

info "Sending prompt to the agent…"
kubectl exec -n "${NS_AGENT}" deploy/langchain-agent -- \
  knative-o-agent prompt "${PROMPT}" || \
  fail "Agent invocation failed — see 'kubectl logs -n ${NS_AGENT} deploy/langchain-agent'"

info "Waiting for ksvc/${TARGET} to report Ready (up to 3 min)…"
if ! kubectl wait -n "${NS_APP}" "ksvc/${TARGET}" \
       --for=condition=Ready --timeout=3m 2>/dev/null; then
  warn "ksvc/${TARGET} not Ready yet. Status:"
  kubectl get -n "${NS_APP}" "ksvc/${TARGET}" -o yaml | sed -n '/status:/,$p' | head -40 || true
  fail "Knative Service did not become Ready"
fi

URL=$(kubectl get -n "${NS_APP}" "ksvc/${TARGET}" -o jsonpath='{.status.url}')
ok "Scenario 1 complete — ksvc/${TARGET} Ready at ${URL}"
echo
echo "In Grafana:"
echo "  make grafana → Dashboards → Knative Serving — Revision"
echo "  filter configuration=${TARGET}; without traffic, pod count is 0."
echo "  Scenario 4 wakes it up and times the cold start."
