#!/usr/bin/env bash
# Scenario 1 — Cold-start deployment via the LLM (§3.3 #1).
# Asks the agent to put `currency` on Knative with scale-to-zero, then
# watches for the Knative Service to come up and shows the result.
#
# Why `currency`: it's a leaf service (no other Astronomy Shop service calls
# it through Knative's cluster-local port 80 — they all stay on :8080), so
# putting it on Knative doesn't break the in-cluster mesh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

NS_APP=astronomy-shop
NS_AGENT=mcp
TARGET=currency

info "Scenario 1: cold-start via the LLM"
log "  target service: ${TARGET} in ${NS_APP}"

# Find the upstream image tag so the agent gets a hint.
IMAGE=$(kubectl get deploy -n "${NS_APP}" "${TARGET}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
[[ -n "${IMAGE}" ]] || fail "Could not read image for ${TARGET}; is the app installed?"
log "  current image: ${IMAGE}"

PROMPT=$(cat <<EOF
Convert the \`${TARGET}\` Deployment in the \`${NS_APP}\` namespace into a
Knative Service so we can demonstrate scale-to-zero.

Requirements:
- apiVersion: serving.knative.dev/v1, kind: Service
- name: ${TARGET}, namespace: ${NS_APP}
- image: ${IMAGE} (use exactly this tag)
- containerConcurrency: 100
- timeoutSeconds: 30
- annotations:
    autoscaling.knative.dev/min-scale: "0"
    autoscaling.knative.dev/max-scale: "5"
    autoscaling.knative.dev/target: "100"

Before applying, delete the existing Deployment named \`${TARGET}\` in
\`${NS_APP}\` (its Service is fine to keep — Knative will not collide with it).
Show me the YAML you plan to apply, then proceed.
EOF
)

info "Sending prompt to the agent (this may take 30–90 s while it thinks)…"
echo "----- prompt -----"
echo "${PROMPT}"
echo "------------------"
echo

kubectl exec -n "${NS_AGENT}" deploy/langchain-agent -- \
  knative-o-agent prompt "${PROMPT}" || \
  fail "Agent invocation failed — check 'kubectl logs -n ${NS_AGENT} deploy/langchain-agent'"

info "Waiting for the Knative Service to report Ready (up to 3 min)…"
if ! kubectl wait -n "${NS_APP}" "ksvc/${TARGET}" \
       --for=condition=Ready --timeout=3m 2>/dev/null; then
  warn "ksvc/${TARGET} not Ready yet. Inspect:"
  kubectl get -n "${NS_APP}" "ksvc/${TARGET}" -o yaml | sed -n '/status:/,$p' || true
  fail "Knative Service did not become Ready"
fi

ok "Scenario 1 complete"
echo
echo "Where to look in Grafana:"
echo "  kubectl -n monitoring port-forward svc/prom-grafana 3000:80"
echo "  open http://localhost:3000  →  Dashboards → Knative Serving — Revision"
echo "  Filter by configuration=${TARGET}. With min-scale=0 you should see"
echo "  pod count drop to 0 within ~30 s of no traffic, then bounce up on"
echo "  the next request through the activator."
