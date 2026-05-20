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

Useful while it's running, in another shell:

```bash
watch -n2 'kubectl get ksvc,deploy,po -A | grep -E "knative|astronomy|mcp|monitoring|opentelemetry"'
```

At the end you'll see something like:

```
Knative-O is up.
  Frontend:  http://frontend.astronomy-shop.127.0.0.1.nip.io
  Grafana:   run `kubectl -n monitoring port-forward svc/prom-grafana 3000:80` then http://localhost:3000
  Agent:     run `kubectl -n mcp port-forward svc/langchain-agent 8080:8080`
```

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
docker, no in-cluster pod):

```bash
make agent-dev
# in another shell
knative-o-agent prompt "list knative revisions of frontend"
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
| Force a cold start | `kubectl scale -n astronomy-shop deploy/frontend-00001-deployment --replicas=0` |
| Drop the agent's conversation state | `kubectl rollout restart deploy/langchain-agent -n mcp` |

---

## 8. What's left to do

Roughly in the order I'd tackle them. Each bullet is small enough to be
one PR.

### Must-have before the live demo

- **End-to-end install validation.** YAML/Python parse cleanly, shell is
  syntactically valid, but `make bootstrap` against a real kind cluster
  hasn't been run from a fresh clone yet. Likely first-run rough edges:
  Knative Operator namespace (the upstream release defaults to
  `default` — we apply it as-is; if that breaks, install into
  `knative-operator` ns and watch from there), Kourier service name
  drift across Knative versions, ServiceMonitor label-selectors that the
  upstream Astronomy Shop pods may not carry.
- **Astronomy Shop overlay coverage.** Only `frontend` is converted to
  a Knative Service. Demo scenarios #2–#4 need `recommendation`,
  `currency`, `productcatalog`, `payment` patched the same way. The
  template is `deploy/astronomy-shop/patches/frontend-knative.yaml`.
- **Agent container image actually published.** The Deployment
  references `ghcr.io/kacperszo/knative-o-agent:latest` but nothing
  builds and pushes it yet. Either:
  - Add a GitHub Actions workflow (`.github/workflows/agent-image.yaml`)
    that builds + pushes on main, or
  - Document `make agent-image && kind load docker-image …` as the dev
    flow for now and inline that in `bootstrap.sh`.
- **Demo runbook.** `scripts/scenarios/01-cold-start.sh`,
  `02-canary.sh`, …, one per scenario in §3.3, so the live demo follows
  a clear narrative instead of ad-hoc kubectl.

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
- **Tests.** A unit test for `webhook._format_turn` (no LLM dependency)
  and a `pytest` smoke that exercises the agent against a fake MCP
  server would catch regressions fast.
- **CI.** GitHub Actions: `bash -n` on shell, `yamllint` on `deploy/`,
  `ruff` + `mypy` on `agent/`, kustomize build dry-run, helm template
  lint.

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
