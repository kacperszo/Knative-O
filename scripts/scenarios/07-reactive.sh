#!/usr/bin/env bash
# Scenario 7 — Reactive autoscale, closed-loop (§3.3 #7).
# POSTs a synthetic Alertmanager payload to the agent's /alerts webhook and
# watches the agent act on it. Requires AGENT_MODE=auto in .env (so the
# agent applies the patch without waiting for human confirmation).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"
load_env

NS_APP=astronomy-shop
NS_AGENT=mcp
TARGET=${KNATIVE_TARGET:-currency-knative}

info "Scenario 7: reactive autoscale via Alertmanager → agent"

if ! kubectl -n "${NS_APP}" get "ksvc/${TARGET}" >/dev/null 2>&1; then
  fail "ksvc/${TARGET} doesn't exist. Run scenario 1 first."
fi

CURRENT_MODE=$(kubectl -n "${NS_AGENT}" get deploy langchain-agent \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AGENT_MODE")].value}' || true)
if [[ "${CURRENT_MODE}" != "auto" ]]; then
  warn "Agent is in '${CURRENT_MODE:-confirm}' mode. Switching to 'auto' for this scenario."
  kubectl -n "${NS_AGENT}" set env deploy/langchain-agent AGENT_MODE=auto
  kubectl -n "${NS_AGENT}" rollout status deploy/langchain-agent --timeout=3m
fi

BEFORE_MAX=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" \
  -o jsonpath='{.spec.template.metadata.annotations.autoscaling\.knative\.dev/max-scale}')
BEFORE_TGT=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" \
  -o jsonpath='{.spec.template.metadata.annotations.autoscaling\.knative\.dev/target}')
log "  before: max-scale=${BEFORE_MAX:-unset} target=${BEFORE_TGT:-unset}"

# Port-forward the agent so we can reach /alerts from the host.
kubectl -n "${NS_AGENT}" port-forward svc/langchain-agent 18080:8080 >/dev/null 2>&1 &
PF_PID=$!
trap "kill ${PF_PID} 2>/dev/null || true" EXIT
sleep 2

PAYLOAD=$(cat <<EOF
{
  "version": "4",
  "status": "firing",
  "receiver": "knative-o-agent",
  "alerts": [{
    "status": "firing",
    "labels": {
      "alertname": "HighRequestLatency",
      "severity": "warning",
      "channel": "agent",
      "namespace_name": "${NS_APP}",
      "configuration_name": "${TARGET}",
      "revision_name": "$(kubectl -n ${NS_APP} get ksvc/${TARGET} -o jsonpath='{.status.latestReadyRevisionName}')"
    },
    "annotations": {
      "summary": "p95 latency on ${TARGET} is 1.4s, above the 1s SLO",
      "remediation_hint": "raise max-scale and lower the concurrency target so it scales out sooner"
    }
  }]
}
EOF
)

info "Firing synthetic alert at the agent webhook…"
HTTP_CODE=$(curl -s -o /tmp/alert-reply.json -w "%{http_code}" \
  -X POST http://localhost:18080/alerts \
  -H "Authorization: Bearer ${WEBHOOK_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")
log "  webhook returned HTTP ${HTTP_CODE}"
if [[ "${HTTP_CODE}" != "202" ]]; then
  cat /tmp/alert-reply.json
  fail "Webhook rejected the alert (expected 202; got ${HTTP_CODE})"
fi

info "Watching for the agent's patch to land (up to 90 s)…"
for _ in $(seq 1 18); do
  NEW_MAX=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" \
    -o jsonpath='{.spec.template.metadata.annotations.autoscaling\.knative\.dev/max-scale}')
  NEW_TGT=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" \
    -o jsonpath='{.spec.template.metadata.annotations.autoscaling\.knative\.dev/target}')
  if [[ "${NEW_MAX}" != "${BEFORE_MAX}" || "${NEW_TGT}" != "${BEFORE_TGT}" ]]; then
    ok "  agent patched the service: max-scale ${BEFORE_MAX} → ${NEW_MAX}, target ${BEFORE_TGT} → ${NEW_TGT}"
    break
  fi
  sleep 5
done

if [[ "${NEW_MAX}" == "${BEFORE_MAX}" && "${NEW_TGT}" == "${BEFORE_TGT}" ]]; then
  warn "No change observed after 90 s. Check the agent's reasoning:"
  echo "  kubectl logs -n ${NS_AGENT} deploy/langchain-agent --tail=200"
  fail "Reactive remediation did not apply"
fi

ok "Scenario 7 complete — closed loop verified"
echo
echo "What just happened:"
echo "  Alertmanager → /alerts → agent (auto mode) → LLM proposed a patch →"
echo "  agent applied it via MCP → ksvc/${TARGET} updated. No human in the loop."
echo
echo "Agent transcript:"
cat /tmp/alert-reply.json | (jq -r .reply 2>/dev/null || cat)
