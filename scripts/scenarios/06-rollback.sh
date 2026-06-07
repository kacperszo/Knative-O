#!/usr/bin/env bash
# Scenario 6 — Rollback via the LLM (§3.3 #6).
# Assumes scenario 2 was run (currency has at least 2 revisions and a 90/10
# split). Asks the agent to send 100% of traffic back to the previous
# revision.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

NS_APP=astronomy-shop
NS_AGENT=mcp
TARGET=currency

info "Scenario 6: rollback ${TARGET} to the previous revision"

if ! kubectl -n "${NS_APP}" get "ksvc/${TARGET}" >/dev/null 2>&1; then
  fail "ksvc/${TARGET} doesn't exist."
fi

REVS=$(kubectl -n "${NS_APP}" get revision \
  -l "serving.knative.dev/service=${TARGET}" \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
COUNT=$(echo "${REVS}" | wc -l | tr -d ' ')
if (( COUNT < 2 )); then
  fail "${TARGET} has only ${COUNT} revision. Run scenario 2 first to create a v2."
fi

# Previous = second-to-last
PREV=$(echo "${REVS}" | tail -2 | head -1)
LATEST=$(echo "${REVS}" | tail -1)
log "  previous revision: ${PREV}"
log "  latest revision:   ${LATEST}"

PROMPT=$(cat <<EOF
Roll back the Knative Service \`${TARGET}\` in namespace \`${NS_APP}\` so
that 100% of traffic goes to revision \`${PREV}\` (the one before the most
recent rollout). Patch .spec.traffic accordingly:

traffic:
- revisionName: ${PREV}
  percent: 100

Echo the patch, then apply it.
EOF
)

info "Sending prompt to the agent…"
kubectl exec -n "${NS_AGENT}" deploy/langchain-agent -- \
  knative-o-agent prompt "${PROMPT}" || \
  fail "Agent invocation failed"

info "Waiting for traffic to settle on ${PREV}…"
for _ in $(seq 1 12); do
  PCT=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" \
    -o jsonpath="{.status.traffic[?(@.revisionName=='${PREV}')].percent}" 2>/dev/null || true)
  if [[ "${PCT}" == "100" ]]; then
    ok "  100% traffic on ${PREV}"
    break
  fi
  log "  current ${PREV}: ${PCT:-?}%"
  sleep 5
done

if [[ "${PCT:-}" != "100" ]]; then
  fail "Rollback didn't take. Final traffic state:
$(kubectl -n "${NS_APP}" get ksvc/${TARGET} -o jsonpath='{.status.traffic}')"
fi

ok "Scenario 6 complete"
echo
echo "In Grafana:"
echo "  Dashboards → Knative Serving — Revision; the request-rate line for"
echo "  ${LATEST} drops to zero within seconds while ${PREV} takes over."
