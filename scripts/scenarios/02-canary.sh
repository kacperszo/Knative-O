#!/usr/bin/env bash
# Scenario 2 — Canary traffic split via the LLM (§3.3 #2).
# Asks the agent to create a new revision of currency-knative and route 10%
# of traffic to it, leaving 90% on the previous one. Requires scenario 1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

NS_APP=astronomy-shop
NS_AGENT=mcp
TARGET=${KNATIVE_TARGET:-currency-knative}

info "Scenario 2: 90/10 canary on ${TARGET}"

if ! kubectl -n "${NS_APP}" get "ksvc/${TARGET}" >/dev/null 2>&1; then
  fail "ksvc/${TARGET} doesn't exist. Run scenario 1 first: make scenario-1"
fi

CURRENT_REV=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" \
  -o jsonpath='{.status.latestReadyRevisionName}')
log "  current ready revision: ${CURRENT_REV}"

# Create a unique string using a timestamp to guarantee a new revision cuts every run
RUN_ID=$(date +%s)

PROMPT="Update the Knative Service named ${TARGET} in namespace ${NS_APP} to do a 90/10 canary traffic split.

Step 1: Use the resources_get tool to read the FULL current Service spec.
Step 2: Modify it as follows:
  - Add or change spec.template.metadata.annotations to include canary.knative-o.dev/revision: v-${RUN_ID} (this forces a new revision without changing the image).
  - Set spec.traffic to exactly this list of two entries:
      - revisionName: ${CURRENT_REV}
        percent: 90
      - latestRevision: true
        percent: 10
  - Preserve ALL other fields exactly as they are (containers, ports, env, resources, annotations on the Service itself, etc.). Do NOT drop or null out any existing field.
Step 3: Apply the FULL modified Service spec via resources_create_or_update. The body MUST include spec.template.spec.containers from step 1, otherwise the Knative webhook will reject it as invalid.

APPLY IT IMMEDIATELY. Do not ask for confirmation; this is a non-interactive batch invocation."

info "Sending prompt to the agent…"
kubectl exec -n "${NS_AGENT}" deploy/langchain-agent -- \
  env AGENT_MODE=auto knative-o-agent prompt "${PROMPT}" || \
  fail "Agent invocation failed — see kubectl logs -n ${NS_AGENT} deploy/langchain-agent"

info "Waiting for traffic split (up to 2 min)…"
TRAFFIC=""
for _ in $(seq 1 24); do
  TRAFFIC=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" \
    -o jsonpath='{range .status.traffic[*]}{.revisionName}={.percent}{"\n"}{end}' 2>/dev/null || true)
  if [[ $(printf '%s\n' "${TRAFFIC}" | grep -c .) -ge 2 ]]; then
    ok "  traffic split applied:"
    printf '%s\n' "${TRAFFIC}" | sed 's/^/    /'
    break
  fi
  sleep 5
done

if [[ $(printf '%s\n' "${TRAFFIC}" | grep -c .) -lt 2 ]]; then
  fail "Traffic split not reflected after 2 min. Current status: ${TRAFFIC}"
fi

info "Generating concurrent load for 60 seconds to trigger autoscaling..."
URL=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" -o jsonpath='{.status.url}')

if [[ -z "${URL}" ]]; then
  fail "Could not resolve Knative service external URL."
fi

log "  Target URL: ${URL}"
log "  Spawning 12 concurrent worker loops..."

# Spawn parallel background loops using pure curl
for worker in {1..12}; do
  (
    END_TIME=$((SECONDS + 60))
    while [ $SECONDS -lt $END_TIME ]; do
      curl -s -o /dev/null "$URL" || true
      sleep 0.02
    done
  ) &
done

log "  Load generation active. Keep checking your Grafana dashboard!"
wait # Blocks execution here until all 60-second background workers finish

ok "Scenario 2 complete"
echo
echo "In Grafana (make grafana → Knative-O — Revisions): you should see two"
echo "revisions for ${TARGET} with request rates roughly in the 9:1 ratio."