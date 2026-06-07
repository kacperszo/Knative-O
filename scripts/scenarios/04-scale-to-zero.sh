#!/usr/bin/env bash
# Scenario 4 — Scale-to-zero proof (§3.3 #4).
# Doesn't need the LLM — this is the observation half of the demo. We pause
# the Astronomy Shop load-generator so `currency` stops receiving traffic,
# then watch pod count go to zero. Restoring the load gen demonstrates the
# activator-driven cold start.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

NS_APP=astronomy-shop
TARGET=currency
LOADGEN_DEPLOY=load-generator

info "Scenario 4: scale-to-zero proof for ${TARGET}"

if ! kubectl -n "${NS_APP}" get "ksvc/${TARGET}" >/dev/null 2>&1; then
  fail "ksvc/${TARGET} doesn't exist. Run scenario 1 first."
fi

current_pods() {
  kubectl -n "${NS_APP}" get pods \
    -l "serving.knative.dev/service=${TARGET}" \
    --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' '
}

info "Pausing load-generator (scale to 0)…"
kubectl -n "${NS_APP}" scale "deploy/${LOADGEN_DEPLOY}" --replicas=0
ok "  load-generator paused"

info "Watching ${TARGET} pod count (scale-to-zero grace period is ~30 s)…"
deadline=$(( $(date +%s) + 180 ))
while (( $(date +%s) < deadline )); do
  n=$(current_pods)
  log "  ${TARGET} active pods: ${n}"
  if (( n == 0 )); then
    ok "  scale-to-zero reached"
    break
  fi
  sleep 10
done
if (( n != 0 )); then
  warn "Didn't reach zero in 3 min. Possible causes:"
  echo "  - another service in the cluster keeps probing currency"
  echo "  - autoscaling.knative.dev/min-scale is not 0 on this ksvc"
  echo "    (check: kubectl -n ${NS_APP} get ksvc/${TARGET} -o yaml | grep min-scale)"
fi

info "Restoring load-generator and timing the cold start…"
kubectl -n "${NS_APP}" scale "deploy/${LOADGEN_DEPLOY}" --replicas=1
t0=$(date +%s)
for _ in $(seq 1 30); do
  if (( $(current_pods) > 0 )); then
    dt=$(( $(date +%s) - t0 ))
    ok "  first pod back in ~${dt} s (activator-mediated cold start)"
    break
  fi
  sleep 1
done

ok "Scenario 4 complete"
echo
echo "In Grafana:"
echo "  Dashboards → Knative Serving — Activator; the *Activator request"
echo "  count* spike at restoration is the cold-start request being held"
echo "  while the first pod boots."
