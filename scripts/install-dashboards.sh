#!/usr/bin/env bash
# Wrap dashboard JSONs in deploy/observability/dashboards/*.json as
# ConfigMaps with the `grafana_dashboard: "1"` label so Grafana's sidecar
# (kube-prometheus-stack default) auto-imports them on the next reconcile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

DASH_DIR="${REPO_ROOT}/deploy/observability/dashboards"
shopt -s nullglob
files=("${DASH_DIR}"/*.json)
(( ${#files[@]} > 0 )) || fail "no dashboards in ${DASH_DIR}"

for f in "${files[@]}"; do
  name="$(basename "${f}" .json)"
  info "Loading dashboard: ${name}"
  kubectl create configmap "grafana-dashboard-${name}" \
    --namespace monitoring \
    --from-file="${name}.json=${f}" \
    --dry-run=client -o yaml \
    | kubectl label --local --dry-run=client -o yaml -f - \
        grafana_dashboard=1 app.kubernetes.io/part-of=knative-o \
    | kubectl apply -f -
done

ok "Dashboards loaded into monitoring/. The Grafana sidecar picks them up"
ok "within ~30 s. Open Grafana → Dashboards → Browse → tag 'knative-o'."
