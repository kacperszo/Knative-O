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

# Fetch ONLY healthy (READY=True) revisions, sorted chronologically
info "Scanning cluster for stable rollback targets..."
HEALTHY_REVS=$(kubectl -n "${NS_APP}" get revision \
  -l "serving.knative.dev/service=${TARGET}" \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
  | grep "True" | awk '{print $1}' || true)

COUNT=$(printf '%s\n' "${HEALTHY_REVS}" | grep -c .)
if (( COUNT < 2 )); then
  fail "${TARGET} does not have enough healthy historical revisions to perform a rollback."
fi

# Safe targets pulled strictly from the healthy pool
PREV=$(printf '%s\n' "${HEALTHY_REVS}" | tail -2 | head -1)
LATEST=$(printf '%s\n' "${HEALTHY_REVS}" | tail -1)

log "  target rollback revision (last stable): ${PREV}"
log "  active latest revision:                 ${LATEST}"

# --- AUTOMATIC TRAFFIC RESET ---
info "Pre-resetting traffic to 100% on latest healthy revision (${LATEST}) to ensure a clean rollback transition..."
kubectl patch ksvc "${TARGET}" -n "${NS_APP}" --type=json -p="[
  {\"op\": \"replace\", \"path\": \"/spec/traffic\", \"value\": [{\"revisionName\": \"${LATEST}\", \"percent\": 100, \"latestRevision\": false}]}
]" >/dev/null
sleep 3

log "Initial Knative Routing Table (Before Rollback):"
kubectl -n "${NS_APP}" get ksvc "${TARGET}" -o jsonpath='{range .status.traffic[*]}    {.revisionName} takes {.percent}%{"\n"}{end}'
echo
# -------------------------------

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
    -o jsonpath="{.spec.traffic[?(@.revisionName=='${PREV}')].percent}" 2>/dev/null || true)
  if [[ "${PCT}" == "100" ]]; then
    ok "  100% traffic targeted at ${PREV}"
    break
  fi
  log "  current ${PREV} target: ${PCT:-0}%"
  sleep 5
done

# Check status.traffic to verify Knative successfully shifted routing engines
info "Verifying routing state from Knative engine..."
sleep 2
FINAL_CHECK=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" \
  -o jsonpath="{.status.traffic[?(@.revisionName=='${PREV}')].percent}" 2>/dev/null || true)

if [[ "${FINAL_CHECK}" != "100" ]]; then
  fail "Rollback routing didn't take. Knative status: $(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" -o jsonpath='{.status.traffic}')"
fi

ok "Scenario 6 complete"
echo
log "Final Knative Routing Table (After Rollback):"
kubectl -n "${NS_APP}" get ksvc "${TARGET}" -o jsonpath='{range .status.traffic[*]}    {.revisionName} takes {.percent}%{"\n"}{end}'
echo
echo "In Grafana (make grafana → Knative-O — Revisions): request-rate line"
echo "for ${LATEST} drops to zero while ${PREV} takes over cleanly."