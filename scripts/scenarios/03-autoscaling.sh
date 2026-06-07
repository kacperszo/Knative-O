#!/usr/bin/env bash
# Scenario 3 — Autoscaling tune via the LLM (§3.3 #3).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

NS_APP=astronomy-shop
NS_AGENT=mcp
TARGET=${KNATIVE_TARGET:-currency-knative}

info "Scenario 3: tune autoscaling on ${TARGET}"

if ! kubectl -n "${NS_APP}" get "ksvc/${TARGET}" >/dev/null 2>&1; then
  fail "ksvc/${TARGET} doesn't exist. Run scenario 1 first: make scenario-1"
fi

PROMPT="Update the Knative Service named ${TARGET} in namespace ${NS_APP} to scale out sooner under load.

Step 1: Use resources_get to read the FULL current Service spec.
Step 2: Modify spec.template.metadata.annotations to include exactly these key-value pairs (replace existing values where they differ):
  autoscaling.knative.dev/target: \"50\"
  autoscaling.knative.dev/max-scale: \"20\"
  autoscaling.knative.dev/min-scale: \"0\"
  autoscaling.knative.dev/metric: concurrency
Preserve any other annotations that are already there.
Step 3: Apply the FULL modified Service spec via resources_create_or_update. The body MUST include spec.template.spec.containers from step 1, otherwise the Knative webhook will reject it as invalid (containers cannot be null).

APPLY IT IMMEDIATELY. Do not ask for confirmation."

info "Sending prompt to the agent…"
kubectl exec -n "${NS_AGENT}" deploy/langchain-agent -- \
  env AGENT_MODE=auto knative-o-agent prompt "${PROMPT}" || \
  fail "Agent invocation failed"

info "Verifying annotations"
sleep 5
after=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" \
  -o jsonpath='{.spec.template.metadata.annotations.autoscaling\.knative\.dev/target}')
[[ "${after}" == "50" ]] || fail "target annotation didn't change (got: '${after}')"
maxs=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" \
  -o jsonpath='{.spec.template.metadata.annotations.autoscaling\.knative\.dev/max-scale}')
[[ "${maxs}" == "20" ]] || fail "max-scale annotation didn't change (got: '${maxs}')"

ok "Scenario 3 complete — target=${after} max-scale=${maxs}"
echo
echo "In Grafana (make grafana → Knative-O — Revisions): the *Pods per"
echo "revision* and *Request rate* panels for ${TARGET} react sooner now —"
echo "the autoscaler adds a pod once concurrency goes above 50."
