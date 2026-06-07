#!/usr/bin/env bash
# Show which Knative-related metric names Prometheus actually has, so the
# dashboard can be corrected if Knative renamed them in a recent version.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

PROM_POD=""
for sel in \
    "app.kubernetes.io/name=prometheus" \
    "app=kube-prometheus-stack-prometheus" \
    "app.kubernetes.io/managed-by=prometheus-operator"; do
  PROM_POD=$(kubectl get pod -n monitoring -l "${sel}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "${PROM_POD}" ]] && break
done
[[ -n "${PROM_POD}" ]] || fail "No Prometheus pod found in monitoring"

URL="/api/v1/namespaces/monitoring/pods/${PROM_POD}:9090/proxy/api/v1/label/__name__/values"
RESP=$(kubectl get --raw "${URL}" 2>&1) || fail "Prometheus query failed: ${RESP}"

info "Knative-related metric names currently exposed to Prometheus"
echo
echo "${RESP}" | python3 -c "
import sys, json, re
d = json.load(sys.stdin)
names = d.get('data', [])
patterns = ['revision', 'activator', 'autoscaler', 'queue_', 'webhook_', 'controller_']
grouped = {p: sorted(n for n in names if p in n) for p in patterns}
for p, ns in grouped.items():
    print(f'== {p}* ({len(ns)}) ==')
    for n in ns[:30]:
        print(f'  {n}')
    if len(ns) > 30:
        print(f'  … {len(ns)-30} more')
    print()
"
