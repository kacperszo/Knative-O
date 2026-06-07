#!/usr/bin/env bash
# Scenario 2 — Canary traffic split via the LLM (§3.3 #2).
# Asks the agent to create a new revision of `currency` and route 10% of
# traffic to it, leaving 90% on the previous one. Requires scenario 1
# (currency already on Knative).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

NS_APP=astronomy-shop
NS_AGENT=mcp
TARGET=currency

info "Scenario 2: 90/10 canary on ${TARGET}"

# Prereq: currency must already be a Knative Service.
if ! kubectl -n "${NS_APP}" get "ksvc/${TARGET}" >/dev/null 2>&1; then
  fail "ksvc/${TARGET} doesn't exist. Run scenario 1 first: make scenario-1"
fi

CURRENT_REV=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" \
  -o jsonpath='{.status.latestReadyRevisionName}')
log "  current ready revision: ${CURRENT_REV}"

PROMPT=$(cat <<EOF
Create a new revision of the Knative Service \`${TARGET}\` in namespace
\`${NS_APP}\` and split traffic so 90% goes to the current revision and 10%
goes to the new one. Use the existing image and configuration; force a new
revision by adding (or bumping) an annotation on the revision template, e.g.
\`canary.knative-o.dev/revision: "v2"\` — that's enough to make Knative
create a new revision without changing the image.

Resulting Service must have:
spec:
  template:
    metadata:
      annotations:
        canary.knative-o.dev/revision: "v2"
  traffic:
  - revisionName: ${CURRENT_REV}
    percent: 90
  - latestRevision: true
    percent: 10

Echo the YAML you plan to apply, then apply it.
EOF
)

info "Sending prompt to the agent…"
kubectl exec -n "${NS_AGENT}" deploy/langchain-agent -- \
  knative-o-agent prompt "${PROMPT}" || \
  fail "Agent invocation failed — see kubectl logs -n ${NS_AGENT} deploy/langchain-agent"

info "Waiting for traffic split (up to 2 min)…"
for _ in $(seq 1 24); do
  TRAFFIC=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" \
    -o jsonpath='{range .status.traffic[*]}{.revisionName}={.percent}{"\n"}{end}' 2>/dev/null || true)
  if [[ $(echo "${TRAFFIC}" | wc -l) -ge 2 ]]; then
    ok "  traffic split applied:"
    echo "${TRAFFIC}" | sed 's/^/    /'
    break
  fi
  sleep 5
done

if [[ $(echo "${TRAFFIC}" | wc -l) -lt 2 ]]; then
  fail "Traffic split not reflected after 2 min. Current status: ${TRAFFIC}"
fi

ok "Scenario 2 complete"
echo
echo "In Grafana:"
echo "  Dashboards → Knative Serving — Revision"
echo "  Filter configuration=${TARGET}; you should see two revisions with"
echo "  request rates roughly in the 9:1 ratio (load-generator hits currency"
echo "  via the cart/checkout flow)."
