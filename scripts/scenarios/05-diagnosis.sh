#!/usr/bin/env bash
# Scenario 5 — Diagnosis via the LLM (§3.3 #5).
# Replaces the image with a bad tag, asks the agent to diagnose, restores.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

NS_APP=astronomy-shop
NS_AGENT=mcp
TARGET=${KNATIVE_TARGET:-currency-knative}

info "Scenario 5: diagnosis"

if ! kubectl -n "${NS_APP}" get "ksvc/${TARGET}" >/dev/null 2>&1; then
  fail "ksvc/${TARGET} doesn't exist. Run scenario 1 first."
fi

GOOD_IMAGE=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
BAD_IMAGE="${GOOD_IMAGE%:*}:does-not-exist"
log "  good image: ${GOOD_IMAGE}"
log "  bad image:  ${BAD_IMAGE}"

info "Injecting bad image (this will trigger ImagePullBackOff on the new revision)"
kubectl -n "${NS_APP}" patch "ksvc/${TARGET}" --type=json -p "[
  {\"op\":\"add\",\"path\":\"/spec/template/metadata/annotations/fault.knative-o.dev~1injected\",\"value\":\"$(date +%s)\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${BAD_IMAGE}\"}
]"

log "  waiting ~30 s for the bad revision to fail…"
sleep 30

PROMPT="The Knative Service named ${TARGET} in namespace ${NS_APP} is failing. Diagnose what is wrong.

Use the resources_get tool on the Service, then on its latest Revision, then list pods with label serving.knative.dev/configuration=${TARGET} in ${NS_APP}, then look at their status and at recent events in ${NS_APP}.

Then write a short plain-language report:
  - What is broken?
  - What is the minimal fix?
Do NOT apply any change."

info "Asking the agent to diagnose…"
kubectl exec -n "${NS_AGENT}" deploy/langchain-agent -- \
  env AGENT_MODE=auto knative-o-agent prompt "${PROMPT}" || \
  fail "Agent invocation failed"

echo
info "Restoring the good image so the cluster goes back to a healthy state"
kubectl -n "${NS_APP}" patch "ksvc/${TARGET}" --type=json -p "[
  {\"op\":\"add\",\"path\":\"/spec/template/metadata/annotations/fault.knative-o.dev~1cleared\",\"value\":\"$(date +%s)\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${GOOD_IMAGE}\"}
]"

ok "Scenario 5 complete"
echo
echo "What you saw: the agent walked Service → Revision → Pod → Events"
echo "through MCP tools and reported the cause in natural language."
echo "It did NOT mutate the cluster; diagnosis only."
