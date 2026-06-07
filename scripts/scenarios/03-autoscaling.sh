#!/usr/bin/env bash
# Scenario 3 — Autoscaling tune via the LLM (§3.3 #3).
# Asks the agent to change `currency`'s autoscaling targets (max-scale up,
# concurrency target down) so it scales out sooner under load.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

NS_APP=astronomy-shop
NS_AGENT=mcp
TARGET=currency

info "Scenario 3: tune autoscaling on ${TARGET}"

if ! kubectl -n "${NS_APP}" get "ksvc/${TARGET}" >/dev/null 2>&1; then
  fail "ksvc/${TARGET} doesn't exist. Run scenario 1 first: make scenario-1"
fi

before=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" \
  -o jsonpath='{.spec.template.metadata.annotations}' 2>/dev/null || true)
log "  current annotations: ${before}"

PROMPT=$(cat <<EOF
On the Knative Service \`${TARGET}\` in namespace \`${NS_APP}\`, change the
autoscaling settings so it scales out sooner under load:

- autoscaling.knative.dev/target: "50"        # concurrency 50 per pod (was 100)
- autoscaling.knative.dev/max-scale: "20"     # cap at 20 pods (was 5)
- autoscaling.knative.dev/min-scale: "0"      # keep scale-to-zero
- autoscaling.knative.dev/metric: "concurrency"

The change goes on .spec.template.metadata.annotations of the Service.
Echo the patch you plan to apply, then apply it.
EOF
)

info "Sending prompt to the agent…"
kubectl exec -n "${NS_AGENT}" deploy/langchain-agent -- \
  knative-o-agent prompt "${PROMPT}" || \
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
echo "In Grafana:"
echo "  Dashboards → Knative Serving — Revision; watch the *Pods* and"
echo "  *Concurrency* panels for ${TARGET}. With target=50 the autoscaler"
echo "  will add a pod once average concurrency goes above 50, much sooner"
echo "  than before."
