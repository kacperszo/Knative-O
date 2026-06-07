# Implementation guide

This file covers two things the main `README.md` (the project document)
deliberately doesn't:

1. **How to run** the scaffold checked into this repo.
2. **What's still missing** before the demo from §3 is fully reproducible.

---

## 1. Prerequisites

You need the tools listed in §7.2 of the main `README.md`. On a fresh
machine the shortest path is:

```bash
# macOS (Homebrew)
brew install kind kubectl helm python@3.11 jq

# Linux (Debian/Ubuntu)
sudo apt-get install -y curl jq python3.11 python3-pip
# kind + kubectl + helm: follow upstream install instructions, then verify:
kind   --version       # ≥ 0.25
kubectl version --client --output=yaml | grep gitVersion
helm   version --short # ≥ 3.14
```

Docker (or a compatible runtime — Podman works with a `KIND_EXPERIMENTAL_PROVIDER=podman` env) is required for the local variant.

## 2. First-time setup

```bash
git clone https://github.com/kacperszo/Knative-O.git
cd Knative-O
cp .env.example .env
$EDITOR .env
```

Fill in **at minimum** in `.env`:

| Variable | Notes |
|----------|-------|
| `ANTHROPIC_API_KEY` *or* `OPENAI_API_KEY` | At least one. `LLM_MODEL` defaults to a Claude Sonnet 4.x. |
| `WEBHOOK_TOKEN` | Any non-default random string — `openssl rand -hex 24` is fine. Alertmanager presents this to the agent. |
| `GRAFANA_ADMIN_PASSWORD` | Optional; if empty the bootstrap generates a random one and prints it at the end. |

Everything else has sensible defaults in `.env.example`.

## 3. Bring it up

```bash
make bootstrap
```

This runs `scripts/bootstrap.sh`, which is idempotent and walks the nine
phases described in §7.3 of the main `README.md` (preflight → kind →
cert-manager → Knative Operator → Kourier → observability →
MCP/agent → Astronomy Shop → smoke → summary). Expect ~10–15 minutes on
a cold cache, mostly image pulls in phase 7.

For the **local** target, phase 6 builds the agent image (`AGENT_IMAGE`,
default `knative-o-agent:local`) and loads it straight into the kind cluster
with `kind load docker-image` — no registry, no push. For the **cloud**
target you must push an image yourself and set `AGENT_IMAGE` to its registry
ref; bootstrap then skips the build/load and just pins the Deployment to it.

Useful while it's running, in another shell:

```bash
watch -n2 'kubectl get ksvc,deploy,po -A | grep -E "knative|astronomy|mcp|monitoring|opentelemetry"'
```

At the end you'll see something like:

```
Knative-O is up.
  Frontend:  kubectl -n astronomy-shop port-forward svc/frontend-proxy 8081:8080  → http://localhost:8081
  Grafana:   kubectl -n monitoring   port-forward svc/prom-grafana    3000:80    → http://localhost:3000
  Agent:     kubectl -n mcp          port-forward svc/langchain-agent  8080:8080
```

The Astronomy Shop is installed via its official Helm chart as ordinary
`Deployment`s (entry point: the `frontend-proxy` Envoy Service). It is **not**
on Knative yet — putting a service on Knative is what the LLM agent
demonstrates (scenario #1); see `deploy/astronomy-shop/knative/frontend.yaml`
for the reference manifest and the port-80 caveat.

## 4. Verify it actually works

```bash
# (already part of bootstrap, but you can re-run on its own)
make smoke
```

That checks: frontend returns 200, Prometheus has live targets in
`astronomy-shop`, and the agent's `/healthz` answers.

Open the frontend in a browser (`http://frontend.astronomy-shop.127.0.0.1.nip.io`),
add something to the cart — Grafana should immediately show non-zero
request rates on the *Knative Serving — Revision* dashboard.

## 5. Talk to the agent

### One-shot prompt (no webhook involved)

```bash
# In one shell, expose the agent locally
kubectl -n mcp port-forward svc/langchain-agent 8080:8080

# In another shell — run a prompt through the in-cluster agent process
kubectl exec -n mcp deploy/langchain-agent -- \
  knative-o-agent prompt "List all knative services in astronomy-shop and tell me which ones currently have zero replicas."
```

Or, if you'd rather run the agent locally against your kubeconfig (no
docker, no in-cluster pod). Note: `make agent-dev` installs the Python
package but **not** the `kubernetes-mcp-server` binary — put it on your
`PATH` first (download from the
[releases page](https://github.com/containers/kubernetes-mcp-server/releases)):

```bash
make agent-dev
# in another shell
knative-o-agent prompt "list services in astronomy-shop and their replica counts"
```

### Closed-loop / webhook path

Fake an Alertmanager payload:

```bash
TOKEN=$(grep ^WEBHOOK_TOKEN .env | cut -d= -f2)
curl -sS -X POST http://localhost:8080/alerts \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{
    "status":"firing",
    "alerts":[{
      "status":"firing",
      "labels":{"alertname":"HighRequestLatency","namespace_name":"astronomy-shop","configuration_name":"frontend"},
      "annotations":{"summary":"p95 > 1s","remediation_hint":"raise maxScale"}
    }]
  }'
```

In `confirm` mode (default) the agent just queues the alert and logs
it; switch `AGENT_MODE=auto` in `.env`, re-run `make bootstrap`, and the
agent will actually patch the Knative `Service` in response. **Run
`auto` mode only against the demo namespace** — the RBAC enforces that
already, but it's still the live path.

## 6. Tear it down

```bash
make teardown
```

Local: deletes the kind cluster, leaves the host untouched.
Cloud (`DEPLOY_TARGET=cloud` in `.env`): removes our installs in reverse
phase order; the managed cluster itself is *not* deleted.

## 7. Common operations cheat sheet

| Task | Command |
|------|---------|
| Re-render Secret from `.env` only | `bash scripts/bootstrap.sh # idempotent, only phase 6 mutates` |
| Watch agent logs | `kubectl logs -n mcp deploy/langchain-agent -f` |
| Watch autoscaler decisions | `kubectl logs -n knative-serving deploy/autoscaler -f` |
| Force a cold start (after Knative conversion) | `kubectl scale -n astronomy-shop deploy/currency-00001-deployment --replicas=0` |
| Drop the agent's conversation state | `kubectl rollout restart deploy/langchain-agent -n mcp` |

---

## 8. Known issues / corrected since the first scaffold

The first scaffold shipped some values I'd written from memory; these were
wrong and are now fixed (verified against the live upstream):

- **Astronomy Shop install used a 404 URL.** It fetched
  `…/opentelemetry-demo/v${VERSION}/kubernetes/opentelemetry-demo.yaml`
  with a `v` prefix and version `1.13.0` — that tag does not exist (tags
  have **no** `v` prefix, and `1.13.0` was never a release). Phase 7 now
  installs the **official Helm chart** (`open-telemetry/opentelemetry-demo`,
  `OTEL_DEMO_CHART_VERSION=0.40.9`, appVersion 2.2.0), which also lets us
  pick the namespace and disable the duplicate Grafana/OpenSearch.
- **Agent crashed on shutdown.** `MultiServerMCPClient` has no `close()`;
  `agent.stop()` raised `AttributeError`. It now only calls a teardown
  method if a future adapter version exposes one.
- **`kubernetes-mcp-server` version.** Dockerfile pinned a stale
  `0.0.46`; bumped to `0.0.62` (binary asset name verified).
- **Wrong service / env names** in the frontend manifest (`productcatalog`
  → `product-catalog`, `AD_SERVICE_ADDR` → `AD_ADDR`, etc.). The reference
  Knative manifest now matches the real 2.2.0 contract.
- **Hard Helm version pins** for cert-manager / kube-prometheus-stack /
  otel-operator could 404 on a withdrawn patch. Those pins are now
  optional (empty in `.env` → Helm resolves the latest).
- **MCP server couldn't find the cluster** (`no configuration has been
  provided, try setting KUBERNETES_MASTER`). `kubernetes-mcp-server`
  auto-detection didn't pick up in-cluster auth; the agent Deployment now
  sets `MCP_CLUSTER_PROVIDER=in-cluster`, which the agent passes as
  `--cluster-provider in-cluster`. Left unset for local `agent-dev` so it
  uses your kubeconfig.
- **MCP server still failed with "in-cluster manager cannot be used
  outside of a cluster"** even with the flag set. Root cause: MCP's stdio
  client only inherits a tiny POSIX env subset
  (`HOME, LOGNAME, PATH, SHELL, TERM, USER`) into the server subprocess,
  so `KUBERNETES_SERVICE_HOST` / `KUBERNETES_SERVICE_PORT` were missing
  and `rest.InClusterConfig()` bailed. The agent now explicitly passes
  those (plus proxy vars) through to the MCP subprocess.
- **Phase 6 needed a namespace created in phase 7.** The agent's write
  `Role`/`RoleBinding` live in `astronomy-shop`, which only the app install
  (phase 7) created — so phase 6 failed with "namespace not found". Phase 6
  now creates `astronomy-shop` first (idempotently).
- **"deployment exceeded its progress deadline"** with no obvious cause.
  Old startup order was `agent.start()` (spawn MCP, list tools) **before**
  uvicorn ever bound the port, so any MCP failure looked like a generic
  deadline timeout. Refactored to FastAPI `lifespan`: uvicorn binds first,
  agent init runs as a background task. `/healthz` is liveness (process
  alive); `/readyz` is gated on agent init and returns the actual error
  (503 + body) when MCP fails. The pod no longer CrashLoops on MCP errors,
  so `kubectl logs` works. `make agent-debug` (or `scripts/agent-debug.sh`)
  dumps describe + events + recent logs + previous-container logs +
  `/readyz` + MCP binary smoke + RBAC `can-i` checks in one go; bootstrap
  runs it automatically when the rollout fails.
- **Rollout timed out mid-rollover.** The deployment used `strategy:
  Recreate`, which scales the old pod to 0 first and only then creates
  the new one. With FastAPI graceful shutdown + a fresh ~2 min MCP init,
  the 5-min `wait_rollout` window hit *while the old pod was Terminating
  and the new one didn't exist yet* — so diagnostics showed a
  Terminating pod and `NewReplicaSet: <none>`. Switched to
  `RollingUpdate` (maxSurge=1, maxUnavailable=0): the new pod spins up
  and goes Ready before the old one is killed. Also bumped
  `wait_rollout` to 8 min so MCP init has real headroom.
- **`ServiceAccount "jaeger" … cannot be imported into the current
  release: invalid ownership metadata`** in phase 7. Classic orphan-Helm
  state: a previous run crashed *during* the Astronomy Shop install, so
  Helm wrote some objects but never recorded a release. The next install
  sees `Release does not exist`, tries to re-create those objects, and
  refuses to "take over" the existing ones because they lack the
  `meta.helm.sh/release-*` annotations. Phase 7 now detects this
  (`helm status` fails but tell-tale ServiceAccounts exist) and wipes
  `astronomy-shop` before installing; the namespace-scoped agent RBAC is
  re-applied right after.
- **`RuntimeError: ANTHROPIC_API_KEY is required for Claude models`** even
  with `OPENAI_API_KEY` set. Two stacked bugs: (1) bootstrap created the
  secret with `--from-literal=ANTHROPIC_API_KEY=""` when the env var was
  empty, which made the Deployment mount `ANTHROPIC_API_KEY=""` (pydantic
  loaded that as `""`, not None, so the "needs Claude key" check fired);
  (2) `LLM_MODEL` defaulted to `claude-sonnet-4-6` regardless of which key
  the user actually had. Fixes: bootstrap skips empty `--from-literal`s
  (no phantom empty key in the secret); `Settings` strips empty strings to
  None; preflight matches `LLM_MODEL` to the available key and fails fast
  with a clear message if they're misaligned; bootstrap also pins
  `LLM_MODEL` from `.env` onto the Deployment so it isn't stuck on the
  default. Also fixed `agent-debug.sh` calling `wget` inside the
  python:slim image (no `wget`) — it now uses Python's `urllib`.

## 9. What's left to do

Roughly in the order I'd tackle them. Each bullet is small enough to be
one PR.

### Must-have before the live demo

- **End-to-end install validation.** YAML/Python parse cleanly and shell
  is syntactically valid, but `make bootstrap` has **not** been run end to
  end against a real kind cluster from this environment (the sandbox has
  no Docker/kind and a restricted network allowlist). This is the single
  most important next step. Likely first-run rough edges: Knative Operator
  namespace (the upstream release defaults to `default`), Kourier
  Deployment name across Knative versions, whether disabling the demo
  chart's Grafana/OpenSearch leaves its Collector config valid, and the
  PodMonitor for queue-proxy matching nothing until a service is converted.
- **Knative conversion coverage.** Only `frontend` has a reference
  manifest (`deploy/astronomy-shop/knative/frontend.yaml`), and it carries
  the port-80 caveat. Scenarios #2–#4 want `currency`, `recommendation`,
  `product-catalog`, `payment` too. Start with `currency` (a leaf service,
  no port-80 routing problem).
- **Demo runbook.** `scripts/scenarios/01-cold-start.sh`, `02-canary.sh`,
  … one per scenario in §3.3.

### Should-have

- **Cloud variant overlays.** `deploy/overlays/cloud/` with: Kourier
  Service of type `LoadBalancer`, cert-manager `ClusterIssuer` for
  Let's Encrypt, wildcard DNS instructions, Tempo instead of Zipkin.
  Right now `DEPLOY_TARGET=cloud` works for the script flow but the user
  has to bring their own DNS/TLS.
- **Confirm-mode UX.** In `confirm` mode the agent currently just logs
  the proposed action. A tiny operator CLI client (`knative-o-agent
  chat`) that streams the conversation and lets you press Enter to
  approve would make the live demo much more compelling.
- **Single observability stack.** Right now we keep the demo chart's
  bundled Prometheus + Jaeger (so its Collector config stays valid) *and*
  run our own kube-prometheus-stack for the Knative control plane — two
  Prometheis. Consolidate by pointing the demo Collector at our backends
  and disabling the chart's Prometheus, or by adding the demo Prometheus
  as an extra Grafana datasource.
- **Tests.** A unit test for `webhook._format_turn` (no LLM dependency)
  and a `pytest` smoke that exercises the agent against a fake MCP
  server would catch regressions fast.
- **CI.** GitHub Actions: `bash -n` on shell, `yamllint` on `deploy/`,
  `ruff` + `mypy` on `agent/`, `helm template` lint.

### Nice-to-have

- **More alert rules**, tuned after a real run. We'll see in the dashboards
  which thresholds are too noisy.
- **Grafana dashboard provisioning.** Pre-load
  `knative-extensions/monitoring` dashboards via a ConfigMap with the
  `grafana_dashboard` label so they show up out of the box.
- **Trace correlation.** Add the OTel collector exemplars config and
  link Prometheus panels to Tempo traces in Grafana.
- **GitOps option.** Argo CD `Application`s wrapping the same kustomize
  bases, for users who want the same install via GitOps.

### Documentation gaps in the main README

These sections are still placeholders:

- §8a/b Demo Deployment Steps (covered partially by `IMPLEMENTATION.md`
  but the formal write-up in the project document is missing).
- §9 Demo Description — execution procedure + results presentation.
- §10 Summary and Conclusions (write after the first end-to-end run).
