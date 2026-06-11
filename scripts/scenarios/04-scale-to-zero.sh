#!/usr/bin/env bash
# Scenario 4 — Scale-to-zero proof (§3.3 #4).
# No LLM — this is the observation half of the demo. ksvc/currency-knative
# isn't wired into the Astronomy Shop's checkout flow (other services call
# the original `currency` Deployment on :8080), so it sits at 0 replicas
# until something requests it through Kourier. We use that to demonstrate
# scale-from-zero precisely: wake it up once, time the cold start.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

NS_APP=astronomy-shop
TARGET=${KNATIVE_TARGET:-currency-knative}

info "Scenario 4: scale-to-zero proof for ${TARGET}"

if ! kubectl -n "${NS_APP}" get "ksvc/${TARGET}" >/dev/null 2>&1; then
  fail "ksvc/${TARGET} doesn't exist. Run scenario 1 first."
fi

URL=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" -o jsonpath='{.status.url}')
[[ -n "${URL}" ]] || fail "ksvc/${TARGET} has no URL yet"
log "  URL: ${URL}"

current_pods() {
  kubectl -n "${NS_APP}" get pods \
    -l "serving.knative.dev/service=${TARGET}" \
    --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' '
}

info "Initial pod count for ${TARGET}: $(current_pods)"
if (( $(current_pods) > 0 )); then
  warn "  pods are running. Wait ~60 s for scale-to-zero, or send 0 traffic."
  log "  watching for scale-to-zero (up to 2 min)…"
  deadline=$(( $(date +%s) + 120 ))
  while (( $(date +%s) < deadline )); do
    n=$(current_pods)
    [[ -t 1 ]] && printf '\r  %ss ago: %s pods   ' \
      "$(( deadline - $(date +%s) - 120 ))" "${n}"
    (( n == 0 )) && { echo; ok "  scale-to-zero reached"; break; }
    sleep 5
  done
  echo
fi

info "Cold-start test: hitting ${URL} once and timing how long it takes…"
t0_ms=$(($(date +%s%N) / 1000000))
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 "${URL}/" || echo "000")
t1_ms=$(($(date +%s%N) / 1000000))
dt=$(( t1_ms - t0_ms ))
log "  first response: HTTP ${HTTP_CODE} in ${dt} ms"
# Currency is gRPC, so HTTP/1 hits it with garbage and we'll get 4xx/5xx.
# We don't care about the body; the point is the activator booted a pod.

info "Pod count after the request: $(current_pods)"
ok "Scenario 4 complete — cold-start took ~${dt} ms (activator + scheduler + image-pull cache)"

echo
echo "In Grafana:"
echo "  Dashboards → Knative Serving — Activator; the request-count spike"
echo "  you just produced is the cold start, and *Activator concurrency*"
echo "  briefly shows 1 while it queued your request waiting for the pod."
echo "  Dashboards → Knative Serving — Revision; pod count for ${TARGET}"
echo "  jumped 0 → 1 at the moment of the request, will fall back to 0 in"
echo "  ~30–60 s of idle (scale-to-zero-grace-period in KnativeServing CR)."
