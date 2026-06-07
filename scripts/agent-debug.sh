#!/usr/bin/env bash
# Surface everything you'd want to know when the agent rollout fails.
# Safe to re-run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS=mcp
DEP=langchain-agent

info "Deployment status"
kubectl get deploy -n "${NS}" "${DEP}" -o wide || true
echo
kubectl describe deploy -n "${NS}" "${DEP}" 2>&1 | sed -n '/Conditions:/,/^Events:/p' || true
echo

info "Pods"
kubectl get pods -n "${NS}" -l app.kubernetes.io/name="${DEP}" -o wide || true
echo

for pod in $(kubectl get pods -n "${NS}" -l app.kubernetes.io/name="${DEP}" -o name); do
  echo
  info "==> ${pod}"

  echo "--- container statuses ---"
  kubectl get "${pod}" -n "${NS}" -o jsonpath='{range .status.containerStatuses[*]}{.name}: ready={.ready} restarts={.restartCount} state={.state}{"\n"}{end}' 2>&1
  echo

  echo "--- events ---"
  kubectl get events -n "${NS}" --field-selector "involvedObject.name=$(basename "${pod}")" \
    --sort-by=.lastTimestamp 2>&1 | tail -20

  echo
  echo "--- recent logs (last 100 lines) ---"
  kubectl logs -n "${NS}" "${pod}" --tail=100 2>&1 || true

  echo
  echo "--- previous container logs (if any restart) ---"
  kubectl logs -n "${NS}" "${pod}" --previous --tail=100 2>&1 | head -50 || true

  echo
  echo "--- /readyz (gated on agent + MCP init) ---"
  # The image is python:slim — no wget/curl. Use Python's urllib instead.
  kubectl exec -n "${NS}" "${pod}" -- python3 -c \
    "import sys,urllib.request as u;r=u.urlopen('http://localhost:8080/readyz');print(r.status);print(r.read().decode())" \
    2>&1 || echo "(readyz unreachable — uvicorn may not be listening yet)"

  echo
  echo "--- MCP binary smoke test (in-cluster) ---"
  kubectl exec -n "${NS}" "${pod}" -- /usr/local/bin/kubernetes-mcp-server --help 2>&1 | head -5 || \
    echo "(mcp binary missing or non-executable)"
done

echo
info "RBAC: can the agent's ServiceAccount actually do what it needs?"
for verb_res in "get nodes" "list pods" "get services.serving.knative.dev" "create services.serving.knative.dev -n astronomy-shop"; do
  read -r verb res rest <<<"${verb_res}"
  ns_args=""
  [[ "${rest}" == "-n astronomy-shop" ]] && ns_args="-n astronomy-shop"
  out=$(kubectl auth can-i "${verb}" "${res}" ${ns_args} \
    --as=system:serviceaccount:mcp:langchain-agent 2>&1)
  printf "  %-55s -> %s\n" "${verb} ${res} ${rest}" "${out}"
done

ok "Done. If the deployment is still not Ready, paste the logs and /readyz output."
