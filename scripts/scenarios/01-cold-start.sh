#!/usr/bin/env bash
# Scenario 1 — Cold-start deployment via the LLM (§3.3 #1).
# Asks the agent to deploy a Knative Service that wraps the same image AND
# env as the existing Astronomy Shop `currency` Deployment, under a
# DIFFERENT name (`currency-knative`). The original Deployment and Service
# stay running — converting `currency` directly would break the shop
# because other services call currency:8080 and Knative cluster-local
# Services answer on :80.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

NS_APP=astronomy-shop
NS_AGENT=mcp
SOURCE=currency
TARGET=${KNATIVE_TARGET:-currency-knative}

info "Scenario 1: cold-start ${TARGET} (wrapping ${SOURCE}'s image+env)"

IMAGE=$(kubectl get deploy -n "${NS_APP}" "${SOURCE}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
[[ -n "${IMAGE}" ]] || fail "Could not read image for Deployment/${SOURCE}; is the app installed?"
log "  source image: ${IMAGE}"

# Pull the env block from the source Deployment so we don't miss anything
# the container actually needs (flagd, OTel collector, ports, etc.). We
# drop fieldRef-backed vars because Knative Services don't have the same
# pod labels available to mirror them; replace OTEL_SERVICE_NAME with the
# Knative service name.
ENV_BLOCK=$(kubectl get deploy -n "${NS_APP}" "${SOURCE}" -o json \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
envs = d['spec']['template']['spec']['containers'][0].get('env', [])
out = []
for e in envs:
    if 'valueFrom' in e:
        if e['name'] == 'OTEL_SERVICE_NAME':
            out.append({'name': 'OTEL_SERVICE_NAME', 'value': '${TARGET}'})
        # skip other fieldRefs — they reference labels we don't set
        continue
    out.append({'name': e['name'], 'value': str(e.get('value', ''))})
print(json.dumps(out, indent=2))
")
log "  env vars copied: $(echo "${ENV_BLOCK}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')"

PROMPT=$(cat <<EOF
Create a new Knative Service named \`${TARGET}\` in namespace \`${NS_APP}\`
to demonstrate scale-to-zero. Use the same image AND env as the existing
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
    env (use exactly this JSON, converted to YAML):
${ENV_BLOCK}

APPLY IT IMMEDIATELY using the \`resources_create_or_update\` tool. Do
not ask for confirmation — this is a non-interactive batch invocation.
EOF
)

info "Sending prompt to the agent…"
kubectl exec -n "${NS_AGENT}" deploy/langchain-agent -- \
  env AGENT_MODE=auto knative-o-agent prompt "${PROMPT}" || \
  fail "Agent invocation failed — see 'kubectl logs -n ${NS_AGENT} deploy/langchain-agent'"

info "Waiting for ksvc/${TARGET} to report Ready (up to 4 min)…"
if ! kubectl wait -n "${NS_APP}" "ksvc/${TARGET}" \
       --for=condition=Ready --timeout=4m 2>/dev/null; then
  warn "ksvc/${TARGET} not Ready. Diagnosing:"
  echo
  echo "--- ksvc status ---"
  kubectl get -n "${NS_APP}" "ksvc/${TARGET}" \
    -o jsonpath='{.status.conditions}' | python3 -m json.tool 2>/dev/null || true
  echo
  REV=$(kubectl get -n "${NS_APP}" "ksvc/${TARGET}" \
    -o jsonpath='{.status.latestCreatedRevisionName}' 2>/dev/null || true)
  if [[ -n "${REV}" ]]; then
    echo "--- revision ${REV} conditions ---"
    kubectl get -n "${NS_APP}" "revision/${REV}" \
      -o jsonpath='{.status.conditions}' | python3 -m json.tool 2>/dev/null || true
    echo
    echo "--- pods for revision ---"
    kubectl get pods -n "${NS_APP}" -l "serving.knative.dev/revision=${REV}"
    echo
    echo "--- pod logs (user-container, last 50 lines) ---"
    kubectl logs -n "${NS_APP}" -l "serving.knative.dev/revision=${REV}" \
      -c user-container --tail=50 --all-containers=false 2>&1 || true
    echo
    echo "--- queue-proxy logs (last 30 lines) ---"
    kubectl logs -n "${NS_APP}" -l "serving.knative.dev/revision=${REV}" \
      -c queue-proxy --tail=30 2>&1 | head -50 || true
    echo
    echo "--- recent events ---"
    kubectl get events -n "${NS_APP}" --sort-by=.lastTimestamp 2>&1 | tail -15
  fi
  fail "Knative Service did not become Ready"
fi

URL=$(kubectl get -n "${NS_APP}" "ksvc/${TARGET}" -o jsonpath='{.status.url}')
ok "Scenario 1 complete — ksvc/${TARGET} Ready at ${URL}"
echo
echo "In Grafana:"
echo "  make grafana → Dashboards → Knative Serving — Revision"
echo "  filter configuration=${TARGET}; without traffic, pod count is 0."
echo "  Scenario 4 wakes it up and times the cold start."
