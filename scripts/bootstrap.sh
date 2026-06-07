#!/usr/bin/env bash
# Idempotent bootstrap. Implements the nine phases described in §7.3.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

bash "${SCRIPT_DIR}/preflight.sh"
load_env

# ----- Phase 1: cluster -----
info "Phase 1: cluster"
if [[ "${DEPLOY_TARGET}" == "local" ]]; then
  if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
    log "kind cluster '${CLUSTER_NAME}' already exists — skipping create"
  else
    kind create cluster --name "${CLUSTER_NAME}" --config "${DEPLOY_DIR}/kind-config.yaml"
  fi
fi
kubectl cluster-info >/dev/null
ok "Cluster reachable"

# ----- Phase 2: cert-manager -----
info "Phase 2: cert-manager"
helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm repo update >/dev/null
# shellcheck disable=SC2046  # word-splitting of version_flag is intended
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  $(version_flag "${CERT_MANAGER_VERSION:-}") \
  --set crds.enabled=true \
  --wait --timeout 5m
ok "cert-manager ready"

# ----- Phase 3: Knative Operator + Serving + Eventing -----
info "Phase 3: Knative Operator"
kubectl apply -f "https://github.com/knative/operator/releases/download/knative-v${KNATIVE_VERSION}/operator.yaml"
wait_crd_established knativeservings.operator.knative.dev
wait_crd_established knativeeventings.operator.knative.dev
wait_rollout deployment knative-operator default 5m || true

kubectl apply -f "${DEPLOY_DIR}/knative/serving.yaml"
kubectl apply -f "${DEPLOY_DIR}/knative/eventing.yaml"

info "Waiting for KnativeServing to be Ready (this is the slow one)…"
wait_condition KnativeServing knative-serving knative-serving Ready 10m
wait_condition KnativeEventing knative-eventing knative-eventing Ready 5m
ok "Knative installed"

# ----- Phase 4: Kourier (declared in KnativeServing) — already up by now -----
info "Phase 4: Kourier reachability check"
kubectl rollout status -n knative-serving deployment/3scale-kourier-gateway --timeout 3m \
  || kubectl rollout status -n kourier-system deployment/3scale-kourier-gateway --timeout 3m
ok "Kourier up"

# ----- Phase 5: observability -----
info "Phase 5: observability stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update >/dev/null
helm repo update >/dev/null

# Render grafana password into the values file via --set (don't write to disk).
# shellcheck disable=SC2046
helm upgrade --install prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  $(version_flag "${KUBE_PROMETHEUS_STACK_VERSION:-}") \
  -f "${DEPLOY_DIR}/observability/prometheus-values.yaml" \
  --set "grafana.adminPassword=${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -hex 12)}" \
  --wait --timeout 10m

# shellcheck disable=SC2046
helm upgrade --install otel-operator open-telemetry/opentelemetry-operator \
  --namespace opentelemetry --create-namespace \
  $(version_flag "${OTEL_OPERATOR_VERSION:-}") \
  --set "manager.collectorImage.repository=otel/opentelemetry-collector-contrib" \
  --wait --timeout 5m
wait_crd_established opentelemetrycollectors.opentelemetry.io

kubectl apply -f "${DEPLOY_DIR}/observability/otel-collector.yaml"
kubectl apply -f "${DEPLOY_DIR}/observability/zipkin.yaml"
kubectl apply -f "${DEPLOY_DIR}/observability/servicemonitors.yaml"
kubectl apply -f "${DEPLOY_DIR}/observability/alert-rules.yaml"

wait_rollout deployment otel-collector opentelemetry 5m
wait_rollout deployment zipkin opentelemetry 3m
ok "Observability stack ready"

# ----- Phase 6: MCP / agent -----
info "Phase 6: MCP / agent"

AGENT_IMAGE="${AGENT_IMAGE:-knative-o-agent:local}"
if [[ "${DEPLOY_TARGET}" == "local" ]]; then
  # Build the agent image locally and load it straight into kind — no registry,
  # no push, works offline after the first image pull.
  case "$(uname -m)" in
    x86_64|amd64)   BUILD_ARCH=amd64 ;;
    aarch64|arm64)  BUILD_ARCH=arm64 ;;
    *) BUILD_ARCH=amd64; warn "Unknown arch $(uname -m); building amd64" ;;
  esac
  log "Building ${AGENT_IMAGE} (${BUILD_ARCH})…"
  docker build --build-arg "TARGETARCH=${BUILD_ARCH}" -t "${AGENT_IMAGE}" "${REPO_ROOT}/agent"
  log "Loading image into kind cluster ${CLUSTER_NAME}…"
  kind load docker-image "${AGENT_IMAGE}" --name "${CLUSTER_NAME}"
else
  if [[ "${AGENT_IMAGE}" == "knative-o-agent:local" ]]; then
    fail "Cloud target needs AGENT_IMAGE set to a registry image your cluster can pull"
  fi
fi

kubectl apply -f "${DEPLOY_DIR}/mcp/namespace.yaml"
# The agent's write RBAC (Role/RoleBinding) lives in the astronomy-shop
# namespace, which the app install (phase 7) creates. Create it here too so
# phase 6 can bind into it; the create is idempotent.
kubectl create namespace astronomy-shop --dry-run=client -o yaml | kubectl apply -f -
# Render Secret from .env. Skip empty values — an empty --from-literal would
# still create the key as "" in the secret, which the Deployment would mount
# as e.g. ANTHROPIC_API_KEY="" and the agent would then believe Claude is
# configured but has no key.
SECRET_ARGS=()
for k in ANTHROPIC_API_KEY OPENAI_API_KEY LANGCHAIN_API_KEY; do
  val="${!k:-}"
  [[ -n "${val}" ]] && SECRET_ARGS+=("--from-literal=${k}=${val}")
done
SECRET_ARGS+=("--from-literal=WEBHOOK_TOKEN=${WEBHOOK_TOKEN}")
kubectl create secret generic agent-secrets \
  --namespace mcp \
  "${SECRET_ARGS[@]}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "${DEPLOY_DIR}/mcp/rbac.yaml"
kubectl apply -f "${DEPLOY_DIR}/mcp/deployment.yaml"
kubectl apply -f "${DEPLOY_DIR}/mcp/service.yaml"
kubectl apply -f "${DEPLOY_DIR}/mcp/networkpolicy.yaml"
# Pin the image and the LLM_MODEL (the Deployment ships a default; .env wins).
kubectl set image -n mcp deployment/langchain-agent "agent=${AGENT_IMAGE}"
kubectl set env   -n mcp deployment/langchain-agent "LLM_MODEL=${LLM_MODEL:-claude-sonnet-4-6}"
if ! wait_rollout deployment langchain-agent mcp 5m; then
  warn "Agent rollout failed — dumping diagnostics:"
  bash "${SCRIPT_DIR}/agent-debug.sh" || true
  fail "Agent did not become Ready. See output above."
fi
ok "Agent up"

# ----- Phase 7: Astronomy Shop (via the official Helm chart) -----
# We install the upstream chart rather than a rendered manifest: the rendered
# kubernetes/*.yaml hardcodes the otel-demo namespace and bundles a second
# observability stack. The chart lets us pick the namespace and disable the
# backends we already run ourselves. The app is deployed as plain Deployments;
# converting a service to Knative is the LLM's job (demo scenario #1), with a
# reference manifest in deploy/astronomy-shop/knative/.
info "Phase 7: Astronomy Shop (Helm)"
kubectl create namespace astronomy-shop --dry-run=client -o yaml | kubectl apply -f -
# shellcheck disable=SC2046
helm upgrade --install astronomy-shop open-telemetry/opentelemetry-demo \
  --namespace astronomy-shop \
  $(version_flag "${OTEL_DEMO_CHART_VERSION:-}") \
  -f "${DEPLOY_DIR}/astronomy-shop/values.yaml" \
  --wait --timeout 12m

info "Waiting for the frontend Deployment…"
wait_rollout deployment frontend astronomy-shop 10m
ok "Astronomy Shop deployed"

# ----- Phase 8: smoke -----
info "Phase 8: smoke test"
bash "${SCRIPT_DIR}/smoke.sh"

# ----- Phase 9: summary -----
info "Phase 9: summary"

cat <<EOF

${C_GREEN}Knative-O is up.${C_OFF}
  Frontend:  run \`kubectl -n astronomy-shop port-forward svc/frontend-proxy 8081:8080\`
             then open http://localhost:8081
  Grafana:   run \`kubectl -n monitoring port-forward svc/prom-grafana 3000:80\`
             then http://localhost:3000 (admin / your GRAFANA_ADMIN_PASSWORD)
  Agent:     run \`kubectl -n mcp port-forward svc/langchain-agent 8080:8080\`
             then POST to http://localhost:8080/alerts with Bearer \${WEBHOOK_TOKEN}

The app runs as plain Deployments. Ask the agent to put a service on Knative
(demo scenario #1), e.g.:
  kubectl exec -n mcp deploy/langchain-agent -- \\
    knative-o-agent prompt "Convert the currency service in astronomy-shop to a Knative Service with scale-to-zero."

Logs:  kubectl logs -n mcp deploy/langchain-agent -f
EOF
