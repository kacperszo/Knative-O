#!/usr/bin/env bash
# Scenario 5 — Diagnosis via the LLM (§3.3 #5).
# Inject a clearly-bad image tag on `currency` so its pods crash, then ask
# the agent to diagnose what's wrong. We don't have it auto-fix here (that's
# scenario 7); we just exercise the read-only diagnosis path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

NS_APP=astronomy-shop
NS_AGENT=mcp
TARGET=currency

info "Scenario 5: diagnosis"

if ! kubectl -n "${NS_APP}" get "ksvc/${TARGET}" >/dev/null 2>&1; then
  fail "ksvc/${TARGET} doesn't exist. Run scenario 1 first."
fi

GOOD_IMAGE=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
BAD_IMAGE="${GOOD_IMAGE%:*}:does-not-exist"
log "  good image: ${GOOD_IMAGE}"
log "  bad image:  ${BAD_IMAGE}"

info "Injecting bad image (this will trigger ImagePullBackOff)…"
kubectl -n "${NS_APP}" patch "ksvc/${TARGET}" --type=merge -p "$(cat <<EOF
{
  "spec": {
    "template": {
      "metadata": { "annotations": { "fault.knative-o.dev/injected": "$(date +%s)" } },
      "spec": { "containers": [ { "image": "${BAD_IMAGE}" } ] }
    }
  }
}
EOF
)"

log "  waiting ~30 s for the bad revision to fail…"
sleep 30

PROMPT=$(cat <<EOF
The Knative Service \`${TARGET}\` in namespace \`${NS_APP}\` is failing.
Diagnose what's wrong. Use the tools to:
1. Look at the latest revision of ${TARGET}.
2. Find the pod(s) for that revision.
3. Read their status and events.
Then tell me, in plain language: what's broken, and what's the minimal fix?
Do NOT apply any change yet.
EOF
)

info "Asking the agent to diagnose…"
kubectl exec -n "${NS_AGENT}" deploy/langchain-agent -- \
  knative-o-agent prompt "${PROMPT}" || \
  fail "Agent invocation failed"

echo
info "Restoring the good image so the cluster goes back to a healthy state"
kubectl -n "${NS_APP}" patch "ksvc/${TARGET}" --type=merge -p "$(cat <<EOF
{
  "spec": {
    "template": {
      "metadata": { "annotations": { "fault.knative-o.dev/cleared": "$(date +%s)" } },
      "spec": { "containers": [ { "image": "${GOOD_IMAGE}" } ] }
    }
  }
}
EOF
)"

ok "Scenario 5 complete"
echo
echo "What you saw: the agent walks the chain Service → Revision → Pod →"
echo "Events through MCP tools, and reports the cause in natural language."
echo "It did NOT mutate the cluster — diagnosis only."
