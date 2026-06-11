#!/usr/bin/env bash
# Scenario 1 — Cold-start deployment via the LLM (§3.3 #1).
# Asks the agent to deploy a Knative Service that wraps the same image AND
# env as the existing Astronomy Shop `currency` Deployment, under a
# DIFFERENT name (`currency-knative`). The original Deployment and Service
# stay running — converting `currency` directly would break the shop
# because other services call currency:8080 and Knative cluster-local
# Services answer on :80.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

NS_APP=astronomy-shop
NS_AGENT=mcp
SOURCE=currency
TARGET=${KNATIVE_TARGET:-currency-knative}

info "Scenario 1: cold-start ${TARGET} (wrapping ${SOURCE}'s image+env)"

IMAGE=$(kubectl get deploy -n "${NS_APP}" "${SOURCE}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
[[ -n "${IMAGE}" ]] || fail "Could not read image for Deployment/${SOURCE}; is the app installed?"
log "  source image: ${IMAGE}"

# Pull the env block from the source Deployment so we don't miss anything
# the container actually needs (flagd, OTel collector, ports, etc.). We
# drop fieldRef-backed vars because Knative Services don't have the same
# pod labels available to mirror them; replace OTEL_SERVICE_NAME with the
# Knative service name.
ENV_BLOCK=$(kubectl get deploy -n "${NS_APP}" "${SOURCE}" -o json \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
envs = d['spec']['template']['spec']['containers'][0].get('env', [])
out = []
for e in envs:
    if 'valueFrom' in e:
        # The chart uses fieldRef for OTEL_SERVICE_NAME (component label).
        # Knative pods don't carry that label; replace with the ksvc name.
        if e['name'] == 'OTEL_SERVICE_NAME':
            out.append({'name': 'OTEL_SERVICE_NAME', 'value': '${TARGET}'})
        # Skip any other fieldRef — currency's C++ binary does
        # std::string(getenv(X)) on some vars; an unset/null env there
        # crashes with 'basic_string: construction from null is not valid'.
        continue
    v = e.get('value')
    if v is None or v == '':
        # Same crash risk if we propagate an empty 'value' as an env var.
        continue
    out.append({'name': e['name'], 'value': str(v)})

# Overrides:
#   OTEL_EXPORTER_PROMETHEUS_PORT — the chart sets 9090, which is Knative's
#     queue-proxy metrics port. Co-locating both in the same pod's network
#     namespace fails the queue-proxy with 'address already in use'. Move
#     currency's exporter to 19090 (it isn't scraped from outside anyway —
#     our Prometheus targets queue-proxy on 9090).
#   OTEL_SERVICE_NAME — make sure it's exactly the ksvc name.
overrides = {
    # Currency's OTel SDK binds a Prometheus exporter inside the pod's
    # network namespace. Knative's queue-proxy sidecar wants 9090 for its
    # own metrics (hardcoded, not configurable). Just disable currency's
    # exporter — we don't scrape it externally; Prometheus targets
    # queue-proxy:9090 for revision request metrics anyway.
    'OTEL_METRICS_EXPORTER': 'none',
    # Belt-and-suspenders in case OTEL_METRICS_EXPORTER isn't honored:
    # move whatever prometheus port currency uses out of 9090.
    'OTEL_EXPORTER_PROMETHEUS_PORT': '19090',
    'OTEL_SERVICE_NAME': '${TARGET}',
}
idx = {e['name']: i for i, e in enumerate(out)}
for k, v in overrides.items():
    if k in idx:
        out[idx[k]]['value'] = v
    else:
        out.append({'name': k, 'value': v})

print(json.dumps(out, indent=2))
")
log "  env vars copied: $(echo "${ENV_BLOCK}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')"

PROMPT=$(cat <<EOF
Create a new Knative Service named \`${TARGET}\` in namespace \`${NS_APP}\`
to demonstrate scale-to-zero. Use the same image AND env as the existing
\`${SOURCE}\` Deployment.

DO NOT touch the existing \`${SOURCE}\` Deployment or its Service — they
must keep running so the rest of the Astronomy Shop continues to work.
Just create the Knative Service alongside.

Manifest to apply (apiVersion: serving.knative.dev/v1, kind: Service):
- name: ${TARGET}, namespace: ${NS_APP}
- annotations on .spec.template.metadata:
    autoscaling.knative.dev/min-scale: "0"
    autoscaling.knative.dev/max-scale: "5"
    autoscaling.knative.dev/target: "100"
    autoscaling.knative.dev/metric: "concurrency"
- containerConcurrency: 100
- timeoutSeconds: 30
- single container:
    name: currency
    image: ${IMAGE}
    ports:
      - containerPort: 8080
    env (use exactly this JSON, converted to YAML):
${ENV_BLOCK}

APPLY IT IMMEDIATELY using the \`resources_create_or_update\` tool. Do
not ask for confirmation — this is a non-interactive batch invocation.
EOF
)

info "Sending prompt to the agent…"
kubectl exec -n "${NS_AGENT}" deploy/langchain-agent -- \
  env AGENT_MODE=auto knative-o-agent prompt "${PROMPT}" || \
  fail "Agent invocation failed — see 'kubectl logs -n ${NS_AGENT} deploy/langchain-agent'"

info "Waiting for ksvc/${TARGET} to report Ready (up to 4 min)…"
if ! kubectl wait -n "${NS_APP}" "ksvc/${TARGET}" \
       --for=condition=Ready --timeout=4m 2>/dev/null; then
  warn "ksvc/${TARGET} not Ready. Diagnosing:"
  echo
  echo "--- ksvc status ---"
  kubectl get -n "${NS_APP}" "ksvc/${TARGET}" \
    -o jsonpath='{.status.conditions}' | python3 -m json.tool 2>/dev/null || true
  echo
  REV=$(kubectl get -n "${NS_APP}" "ksvc/${TARGET}" \
    -o jsonpath='{.status.latestCreatedRevisionName}' 2>/dev/null || true)
  if [[ -n "${REV}" ]]; then
    echo "--- revision ${REV} conditions ---"
    kubectl get -n "${NS_APP}" "revision/${REV}" \
      -o jsonpath='{.status.conditions}' | python3 -m json.tool 2>/dev/null || true
    echo
    echo "--- pods for revision ---"
    kubectl get pods -n "${NS_APP}" -l "serving.knative.dev/revision=${REV}"
    echo
    echo "--- pod env (currency container, as actually applied) ---"
    kubectl get pod -n "${NS_APP}" -l "serving.knative.dev/revision=${REV}" \
      -o jsonpath='{.items[0].spec.containers[?(@.name=="currency")].env}' \
      | python3 -m json.tool 2>&1 | head -60 || true
    echo
    echo "--- pod logs (all containers, last 80 lines, prefixed) ---"
    # Knative keeps the user's container name from the manifest (here:
    # 'currency'), not 'user-container'. Use --all-containers so we don't
    # have to guess; kubectl prefixes lines with the container name.
    kubectl logs -n "${NS_APP}" -l "serving.knative.dev/revision=${REV}" \
      --all-containers=true --prefix=true --tail=80 2>&1 | head -120 || true
    echo
    echo "--- recent events ---"
    kubectl get events -n "${NS_APP}" --sort-by=.lastTimestamp 2>&1 | tail -15
  fi
  fail "Knative Service did not become Ready"
fi

URL=$(kubectl get -n "${NS_APP}" "ksvc/${TARGET}" -o jsonpath='{.status.url}')
ok "Scenario 1 complete — ksvc/${TARGET} Ready at ${URL}"
echo
echo "In Grafana:"
echo "  make grafana → Dashboards → Knative Serving — Revision"
echo "  filter configuration=${TARGET}; without traffic, pod count is 0."
echo "  Scenario 4 wakes it up and times the cold start."
