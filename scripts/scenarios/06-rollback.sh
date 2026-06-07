#!/usr/bin/env bash
# Scenario 6 — Rollback via the LLM (§3.3 #6).
# Assumes scenario 2 was run (ksvc has >= 2 revisions).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

NS_APP=astronomy-shop
NS_AGENT=mcp
TARGET=${KNATIVE_TARGET:-currency-knative}

info "Scenario 6: rollback ${TARGET} to the previous revision"

if ! kubectl -n "${NS_APP}" get "ksvc/${TARGET}" >/dev/null 2>&1; then
  fail "ksvc/${TARGET} doesn't exist."
fi

REVS=$(kubectl -n "${NS_APP}" get revision \
  -l "serving.knative.dev/service=${TARGET}" \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
COUNT=$(printf '%s\n' "${REVS}" | grep -c .)
if (( COUNT < 2 )); then
  fail "${TARGET} has only ${COUNT} revision. Run scenario 2 first to create a v2."
fi

PREV=$(printf '%s\n' "${REVS}" | tail -2 | head -1)
LATEST=$(printf '%s\n' "${REVS}" | tail -1)
log "  previous revision: ${PREV}"
log "  latest revision:   ${LATEST}"

PROMPT="Roll back the Knative Service named ${TARGET} in namespace ${NS_APP} so that 100% of traffic goes to revision ${PREV}.

Step 1: Use resources_get to read the FULL current Service spec.
Step 2: Replace spec.traffic with exactly one entry:
  - revisionName: ${PREV}
    percent: 100
  Preserve ALL other fields exactly as they are (containers, ports, env, annotations, etc.). Do NOT drop or null out any existing field.
Step 3: Apply the FULL modified Service via resources_create_or_update. The body MUST include spec.template.spec.containers from step 1.

APPLY IT IMMEDIATELY. Do not ask for confirmation."

info "Sending prompt to the agent…"
kubectl exec -n "${NS_AGENT}" deploy/langchain-agent -- \
  env AGENT_MODE=auto knative-o-agent prompt "${PROMPT}" || \
  fail "Agent invocation failed"

info "Waiting for traffic to settle on ${PREV}…"
PCT=""
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
  fail "Rollback didn't take. Final traffic state: $(kubectl -n ${NS_APP} get ksvc/${TARGET} -o jsonpath='{.status.traffic}')"
fi

ok "Scenario 6 complete"
echo
echo "In Grafana (make grafana → Knative-O — Revisions): request-rate line"
echo "for ${LATEST} drops to zero while ${PREV} takes over."
