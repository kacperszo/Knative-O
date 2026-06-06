#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

if [[ "${DEPLOY_TARGET}" == "local" ]]; then
  if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
    info "Deleting kind cluster ${CLUSTER_NAME}…"
    kind delete cluster --name "${CLUSTER_NAME}"
    ok "Done"
  else
    warn "kind cluster ${CLUSTER_NAME} not found — nothing to do"
  fi
  exit 0
fi

# Cloud: tear down our resources but leave the managed cluster intact.
info "Cloud teardown — removing demo resources, keeping the cluster"

helm uninstall -n astronomy-shop astronomy-shop || true
kubectl delete -f "${DEPLOY_DIR}/mcp/" --ignore-not-found || true
kubectl delete -f "${DEPLOY_DIR}/observability/alert-rules.yaml" --ignore-not-found || true
kubectl delete -f "${DEPLOY_DIR}/observability/servicemonitors.yaml" --ignore-not-found || true
kubectl delete -f "${DEPLOY_DIR}/observability/otel-collector.yaml" --ignore-not-found || true
kubectl delete -f "${DEPLOY_DIR}/observability/zipkin.yaml" --ignore-not-found || true

helm uninstall -n opentelemetry otel-operator || true
helm uninstall -n monitoring prom || true

kubectl delete -f "${DEPLOY_DIR}/knative/serving.yaml" --ignore-not-found || true
kubectl delete -f "${DEPLOY_DIR}/knative/eventing.yaml" --ignore-not-found || true
kubectl delete -f "https://github.com/knative/operator/releases/download/knative-v${KNATIVE_VERSION}/operator.yaml" --ignore-not-found || true

helm uninstall -n cert-manager cert-manager || true

ok "Cloud resources removed"
