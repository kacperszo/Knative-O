#!/usr/bin/env bash
# Send sustained traffic to a Knative service through Kourier so the
# observability dashboards have something to show.
#
# Usage: bash scripts/demo-traffic.sh [-r RATE] [-d DURATION] [-t TARGET]
#   RATE      — approximate requests per second (default: 5)
#   DURATION  — total seconds to keep sending (default: 120)
#   TARGET    — ksvc name in astronomy-shop (default: currency-knative)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS_APP=astronomy-shop
TARGET=${KNATIVE_TARGET:-currency-knative}
RATE=${RATE:-5}
DURATION=${DURATION:-120}

while getopts "r:d:t:" opt; do
  case ${opt} in
    r) RATE=${OPTARG} ;;
    d) DURATION=${OPTARG} ;;
    t) TARGET=${OPTARG} ;;
    *) fail "usage: $0 [-r RATE] [-d DURATION] [-t TARGET]" ;;
  esac
done

URL=$(kubectl -n "${NS_APP}" get "ksvc/${TARGET}" -o jsonpath='{.status.url}' 2>/dev/null || true)
[[ -n "${URL}" ]] || fail "ksvc/${TARGET} has no URL — does the Knative Service exist?"

info "Generating traffic on ${URL}"
log "  rate=${RATE} req/s, duration=${DURATION}s"
log "  (Open Grafana → Knative-O — Revisions in a second screen.)"

end=$(($(date +%s) + DURATION))
count=0; errors=0; t0=$(date +%s)
while (( $(date +%s) < end )); do
  for _ in $(seq 1 "${RATE}"); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${URL}/" || echo "000")
    count=$((count + 1))
    case "${code}" in
      2*|3*) ;;
      *) errors=$((errors + 1)) ;;
    esac
  done
  # ~1 second cadence (curl loop overhead absorbs the sub-second).
  printf "\r  sent=%d  non-2xx=%d  elapsed=%ds   " \
    "${count}" "${errors}" "$(( $(date +%s) - t0 ))"
  sleep 1
done
echo

# Currency is gRPC; HTTP/1 requests get a 4xx/5xx from the binary. That is
# expected — the activator still booted a pod, queue-proxy still counted
# the request. The metrics that matter (request count, latency, pod count,
# activator activity) light up regardless of body response.
ok "Done. Total requests sent: ${count} (non-2xx: ${errors} is expected for a gRPC backend)"
