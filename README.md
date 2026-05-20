# Knative-O — Serverless Application Observability (Project Type 1)

**Authors:**
- Stanisław Barycki
- Eryk Olejarz
- Paweł Prus
- Kacper Szot

---

## Project Description

The goal of this project is to demonstrate **LLM-driven deployment and management** of a serverless microservice application running on **Knative**, with a full observability pipeline built on **OpenTelemetry**, **Prometheus**, and **Grafana**.

The user issues natural-language commands to an LLM (e.g. Claude), which — through **LangChain** and a **Kubernetes MCP Server** — performs real operations on the cluster: deploying Knative Services, managing revisions, configuring traffic splitting, and adjusting autoscaling. The effects of these operations are then observed and visualized through the observability stack.

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Theoretical Background / Technology Stack](#2-theoretical-background--technology-stack)
3. [Case Study Concept](#3-case-study-concept)
4. [High-Level Architecture](#4-high-level-architecture)
5. [Detailed Architecture](#5-detailed-architecture)
6. [Environment Configuration](#6-environment-configuration)
7. [Installation Method](#7-installation-method)
8. [Demo Deployment Steps](#8-demo-deployment-steps)
9. [Demo Description](#9-demo-description)
10. [Summary and Conclusions](#10-summary-and-conclusions)
11. [References](#11-references)

---

## 1. Introduction

Serverless platforms like Knative simplify application deployment by automating scaling, traffic routing, and revision management. However, operating such systems effectively still requires deep Kubernetes knowledge and manual YAML editing.

This project explores whether an **LLM can replace manual kubectl/YAML workflows** for managing Knative applications. The LLM communicates with the cluster through a Kubernetes MCP Server and performs deployments, configuration changes, and diagnostics — all from natural-language prompts. A full observability stack (OpenTelemetry → Prometheus → Grafana) allows us to verify and visualize the results.

---

## 2. Theoretical Background / Technology Stack

| Component | Technology | Role |
|-----------|-----------|------|
| Orchestration | **Kubernetes** | Container and infrastructure management |
| Serverless Platform | **Knative** (Serving + Eventing) | Autoscaling, revisions, traffic splitting, event-driven communication |
| Telemetry Collection | **OpenTelemetry** | Collecting traces, metrics, and logs from applications and Knative components |
| Metrics Storage | **Prometheus** | Time-series metrics storage and querying (PromQL) |
| Visualization | **Grafana** | Dashboards for metrics, traces, and logs |
| AI Bridge | **MCP Server** (Kubernetes) | Protocol exposing kubectl operations as tools for the LLM |
| Integration | **LangChain** | Framework connecting the LLM to MCP Server tools |
| Brain | **LLM** (Claude / ChatGPT) | Natural-language interface for cluster management |

### Knative

Knative is an open-source platform running on Kubernetes for serverless and event-driven applications. It has two main components:

- **Knative Serving** — deployment, autoscaling (including scale-to-zero), revision management, and traffic splitting between versions.
- **Knative Eventing** — event-driven communication using brokers, triggers, and the CloudEvents specification.

Knative natively supports observability: it emits metrics in Prometheus/OTLP formats, propagates trace context in HTTP headers, and its data-plane components (activator, queue-proxy) are instrumented out of the box.

### Kubernetes MCP Server

The [Kubernetes MCP Server](https://github.com/containers/kubernetes-mcp-server) implements the Model Context Protocol, exposing Kubernetes operations as callable tools for LLMs. It allows the LLM to create, modify, and delete resources, read cluster state, and apply YAML manifests — effectively replacing manual `kubectl` usage.

### OpenTelemetry, Prometheus & Grafana

OpenTelemetry collects telemetry (traces, metrics, logs) from both the application and Knative infrastructure via the OTel Collector. Prometheus stores time-series metrics and serves as the data source for Grafana, which provides the visualization layer. The `knative-extensions/monitoring` repository offers ready-made Grafana dashboards for Knative.

### 2.1 Technology Decisions for the Demo *(corresponds to point 4 of the project document — "Ustalenie technologii realizacji Demo")*

Below is the rationale behind each technology chosen for the demo, including the alternatives considered and the reason for rejection. The selection is driven by three constraints: (1) the demo must run on a single laptop-grade Kubernetes cluster, (2) every component must expose telemetry that can be visualized end-to-end, and (3) the LLM must be able to drive the cluster through a documented, vendor-neutral protocol.

| # | Decision area | Chosen technology | Alternatives considered | Rationale |
|---|---------------|-------------------|-------------------------|-----------|
| 1 | Container orchestrator | **Kubernetes** (kind / managed) | Docker Swarm, Nomad | De-facto standard; required by Knative and the MCP server; works identically locally and in the cloud. |
| 2 | Serverless layer | **Knative Serving + Eventing** | OpenFaaS, Kubeless, KEDA-only, AWS Lambda | Knative is the only CNCF-incubating serverless layer that runs on any Kubernetes, provides revision-level traffic splitting and scale-to-zero out of the box, and is natively instrumented (queue-proxy/activator emit Prometheus + OTLP). The project topic explicitly names Knative. |
| 3 | Telemetry pipeline | **OpenTelemetry Collector** (OTLP) | Direct Prometheus scrape only, Jaeger agent, Fluent Bit only | OTel is vendor-neutral and unifies traces, metrics and logs in one pipeline. The Collector lets us fan out to Prometheus (metrics) and to a tracing backend without re-instrumenting the app. |
| 4 | Metrics backend | **Prometheus** (kube-prometheus-stack) | VictoriaMetrics, Thanos, Mimir | Native target for Knative metrics, smallest footprint for a demo, the `kube-prometheus-stack` Helm chart bundles Alertmanager and node/k8s exporters with sane defaults. |
| 5 | Visualization | **Grafana (OSS)** + ready-made Knative dashboards | Grafana Cloud, Kiali, custom UI | OSS Grafana runs in-cluster, no account required for evaluation. We import dashboards from `knative-extensions/monitoring` so the demo shows production-grade panels from minute one. |
| 6 | LLM bridge | **Kubernetes MCP Server** (containers/kubernetes-mcp-server) | Custom kubectl wrapper, `kubectl-ai`, K8sGPT | MCP is the protocol Claude/Cursor speak natively; one server exposes the full kubectl surface as typed tools, so the LLM cannot escape sandboxing and every call is auditable. |
| 7 | LLM orchestration | **LangChain** (Python) + Claude / ChatGPT | Direct SDK calls, LlamaIndex, custom agent loop | LangChain has first-class MCP support (`langchain-mcp-adapters`), built-in tool calling, conversation memory and tracing — minimal glue code for the demo. |
| 8 | LLM | **Claude (Sonnet/Opus)** with ChatGPT as fallback | Local LLMs (Llama, Mistral) | Frontier models needed for reliable multi-step tool use on Kubernetes manifests; local models are too weak for correct YAML/CRD generation in a short demo. |
| 9 | Demo workload | **OpenTelemetry Astronomy Shop** | Google Online Boutique, knative-demo, knative-tracing | The only candidate that ships with native OTel instrumentation, a built-in load generator, and Prometheus/Grafana wiring — minimizes instrumentation work and lets us focus on the LLM-driven Knative scenarios. See §3.2 for the comparison matrix. |
| 10 | Cluster runtime | **kind** (local) + **GKE/EKS/AKS** (cloud variant) | minikube, k3d, Docker Desktop K8s | kind is the most reproducible single-binary local cluster and the one used by Knative's own quickstart; for a cloud demo we keep the manifests portable to any managed Kubernetes. See §6. |

**Out of scope for the demo (deliberate cuts):** service mesh (Istio/Linkerd), GitOps (Argo CD/Flux), policy engines (OPA/Kyverno), log aggregation (Loki/ELK). They would obscure the LLM ↔ Knative interaction without adding to the project's research question.

---

## 3. Case Study Concept *(corresponds to point 3 of the project document — "Opis Demo")*

### 3.1 Project Goals

- **LLM-driven Knative management:** Deploy and configure serverless applications using natural-language prompts instead of manual YAML/kubectl.
- **Full observability pipeline:** Instrument the application with OpenTelemetry, collect metrics with Prometheus, visualize with Grafana.
- **Verify LLM operations through observability:** Use dashboards to confirm that LLM-driven deployments, scaling changes, and traffic splits work correctly.
- **Reproducibility:** The whole demo must come up on a laptop-class machine from a single bootstrap script and be tearable down to zero with one command.

### 3.2 Demo Application — Selection

We evaluated four candidate applications against four criteria: (a) native OpenTelemetry instrumentation, (b) microservice count meaningful enough to show scale-to-zero and traffic splits, (c) availability of a load generator, (d) effort needed to deploy on Knative.

| Application | OTel native | µservices | Load gen | Knative effort | Verdict |
|-------------|:-----------:|:---------:|:--------:|:--------------:|---------|
| **OpenTelemetry Astronomy Shop** | ✅ | 14 | ✅ (built-in) | Medium — convert `Deployment` → `Service` (Knative) for selected services | **Selected** |
| Google Online Boutique | ❌ (needs adding) | 11 | ✅ (locust) | Medium + instrumentation work | Rejected — instrumentation overhead |
| Knative Eventing Demo | partial | 3 | ❌ | Low | Rejected — too small to show autoscaling differences |
| Knative Tracing Demo | ✅ (traces only) | 2 | ❌ | Low | Rejected — too narrow, traces only |

**Chosen application: [OpenTelemetry Astronomy Shop](https://github.com/open-telemetry/opentelemetry-demo)** — a polyglot (Go, Java, Python, .NET, Node.js, Rust, Ruby, PHP) e-commerce reference application maintained by the OpenTelemetry project. It ships with native OTel SDKs in every service, a `loadgenerator` based on Locust, a feature-flag service, and pre-built Grafana dashboards. For our demo we will:

1. Deploy a **subset** of the services as Knative Services so we can demonstrate scale-to-zero and revision/traffic splitting on real, end-user-facing components (`frontend`, `productcatalog`, `recommendation`, `currency`, `payment`).
2. Keep the **stateful** components (`kafka`, `valkey/redis`, `postgres`, `featureflag`) as regular Deployments + Services — Knative Serving is not suitable for stateful workloads.
3. Replace the demo's bundled OTel Collector / Prometheus / Grafana with our own observability stack so it also receives metrics from the Knative control plane (activator, autoscaler, queue-proxy).

### 3.3 Demo Scenarios

The demo is structured as a single, narrated session in which the operator types only natural-language prompts; every observable change is shown live in Grafana on a second screen.

| # | Scenario | Operator prompt (example) | LLM action | Observable result in Grafana |
|---|----------|---------------------------|-------------|------------------------------|
| 1 | **Cold-start deployment** | "Deploy the Astronomy Shop frontend on Knative with min-scale 0." | Generates `Service` manifest, applies via MCP, waits for `Ready`. | New revision appears in *Knative Serving* dashboard; pod count goes 0→1 on first request. |
| 2 | **Canary traffic split** | "Roll out a v2 of `recommendation` taking 10 % of traffic." | Creates a new revision and patches the `Service` with a 90/10 `traffic` block. | Per-revision request rate panel shows ~10 % share on v2; error/latency comparison side-by-side. |
| 3 | **Autoscaling tune** | "If load spikes, scale `frontend` up faster — target 50 RPS per pod, max 20." | Sets `autoscaling.knative.dev/target` and `maxScale` annotations. | Concurrency vs. pod-count panel responds: pods scale up sooner under load-generator traffic. |
| 4 | **Scale-to-zero proof** | "Stop traffic to `payment` and show me when it scales to zero." | Pauses the load generator for that service, watches pod count. | *Active pods* panel drops to 0 after the grace period; first cold request shows the activator's TTFB spike. |
| 5 | **Diagnosis** | "Why is the cart service failing?" | Reads pod status, recent events, last log lines through MCP; suggests a fix (e.g. wrong env var). | Trace waterfall in Grafana shows the failing span; LLM proposes a patch that the operator applies. |
| 6 | **Rollback** | "Roll back `recommendation` to the previous revision." | Patches `Service` traffic to 100 % on previous revision. | Traffic shifts back; error-rate panel returns to baseline within seconds. |

### 3.4 Acceptance Criteria

The demo is considered successful when, during a single live run:
- All six scenarios above execute end-to-end **without manual `kubectl`** — every cluster mutation goes through the LLM/MCP path.
- Every mutation is **visible on Grafana** within ≤ 30 seconds (Prometheus scrape interval + dashboard refresh).
- The Knative control plane and all OTel pipeline components stay `Ready` for the duration of the demo (no crash-loops, no OOM-kills).
- A spectator with no Kubernetes knowledge can follow the narrative: prompt → action → metric movement.

### 3.5 Expected Outcomes

- A reproducible, scripted bootstrap that brings up Kubernetes + Knative + OTel + Prometheus + Grafana + MCP Server + Astronomy Shop in ≤ 15 minutes.
- A short evaluation of the LLM's reliability on Knative operations (success rate per scenario type, classes of mistakes observed).
- A discussion of what observability did and did not catch — i.e. which LLM mistakes were obvious from the dashboards versus which required reading raw events/logs.

---

## 4. High-Level Architecture

```
        ┌───────────────────┐
        │  Claude / ChatGPT  │
        │  Cursor / ...      │
        │                    │◄──── LangChain
        │       LLM          │
        └────────┬───────────┘
                 │
         ┌───────▼───────┐
         │  MCP Server   │
         │  (Kubernetes) │
         └───────┬───────┘
                 │
                 ▼
┌───────────────────┐   ┌─────────────────┐   ┌──────────────────────┐
│                   │   │                 │   │                      │
│   Application     │──▶│  Observability  │──▶│   Visualization      │
│                   │   │                 │   │                      │
│  Knative          │   │  Prometheus     │   │  Grafana (OSS)       │
│  (Serving +       │   │  OpenTelemetry  │   │  Grafana Cloud       │
│   Eventing)       │   │  ...            │   │  Grafana Assistance  │
│                   │   │                 │   │  ...                 │
└───────────────────┘   └─────────────────┘   └──────────────────────┘
```

The LLM communicates **only with the Application layer** through the MCP Server. The observability and visualization layers operate independently — collecting and displaying telemetry emitted by the application and Knative components.

**Data flow:**
1. User sends a natural-language prompt to the LLM.
2. LLM generates an operation plan; LangChain routes it to the Kubernetes MCP Server.
3. MCP Server executes the operation on the Knative/Kubernetes cluster.
4. Knative Services and components emit telemetry → OpenTelemetry Collector → Prometheus.
5. Grafana dashboards visualize the collected metrics and traces.

---

## 5. Detailed Architecture

---

## 6. Environment Configuration *(corresponds to point 5 of the project document — "Opis konfiguracji")*

This section describes the concrete configuration of every component needed to reproduce the demo. We document **two deployment targets**: a local single-node cluster (the default for the live demo) and a managed cloud cluster (a fallback / scale-up variant). All YAML/Helm values are kept in the repository so the environment is fully declarative.

### 6.1 Hardware and Software Baseline

| Resource | Local (default) | Cloud (variant) |
|----------|-----------------|-----------------|
| Cluster | **kind** v0.24+ (single node, 4 workers) | **GKE / EKS / AKS**, 3× `e2-standard-4` (or equivalent) |
| CPU / RAM | ≥ 6 vCPU / 16 GB RAM on the host | 3× 4 vCPU / 16 GB |
| Disk | 40 GB free for images + Prometheus TSDB | 100 GB SSD PD per node |
| Kubernetes | v1.30.x | v1.30.x (matching managed channel) |
| Container runtime | containerd (bundled with kind) | containerd (managed) |
| Ingress / DNS | `kourier` + `nip.io` magic DNS | Cloud LB + managed DNS zone |
| OS (host) | Linux/macOS, Docker ≥ 24 | n/a (managed) |
| CLI tools | `kubectl`, `helm` ≥ 3.14, `kn` (Knative CLI), `kind`, `python` ≥ 3.11 | + cloud-vendor CLI (`gcloud`/`aws`/`az`) |

### 6.2 Cluster Layout

```
namespace                      purpose
─────────────────────────────  ──────────────────────────────────────────
knative-serving                Knative Serving control plane
knative-eventing               Knative Eventing control plane
kourier-system                 Knative ingress (Kourier)
cert-manager                   TLS certificates for Knative (cloud variant)
monitoring                     kube-prometheus-stack + Grafana
opentelemetry                  OpenTelemetry Operator + Collector(s)
astronomy-shop                 Demo application (Knative Services + Deployments)
mcp                            Kubernetes MCP Server + LangChain runner
```

A dedicated namespace per concern keeps RBAC, NetworkPolicies and Grafana folder structure clean, and lets us tear the demo workload down (`kubectl delete ns astronomy-shop`) without touching the platform.

### 6.3 Knative Configuration

Installed via the **Knative Operator** (declarative, easy to upgrade) with the following `KnativeServing` / `KnativeEventing` settings:

```yaml
apiVersion: operator.knative.dev/v1beta1
kind: KnativeServing
metadata:
  name: knative-serving
  namespace: knative-serving
spec:
  version: "1.15"
  ingress:
    kourier:
      enabled: true
  config:
    autoscaler:
      enable-scale-to-zero: "true"
      scale-to-zero-grace-period: "30s"
      stable-window: "60s"
      container-concurrency-target-default: "100"
    domain:
      "127.0.0.1.nip.io": ""        # local variant — overridden in cloud
    features:
      kubernetes.podspec-affinity: "enabled"
      kubernetes.podspec-tolerations: "enabled"
    observability:
      metrics.backend-destination: "prometheus"
      metrics.request-metrics-backend-destination: "prometheus"
      tracing.backend: "zipkin"
      tracing.zipkin-endpoint: "http://otel-collector.opentelemetry:9411/api/v2/spans"
      tracing.sample-rate: "0.1"
```

Per-service knobs (set via annotations and exercised by demo scenario #3):

| Annotation | Default | Notes |
|------------|---------|-------|
| `autoscaling.knative.dev/min-scale` | `0` | `1` for `frontend` to avoid cold start during the live demo |
| `autoscaling.knative.dev/max-scale` | `10` | raised to `20` in scenario #3 |
| `autoscaling.knative.dev/target` | `100` | concurrency target per pod |
| `autoscaling.knative.dev/metric` | `concurrency` | switched to `rps` for `recommendation` |

### 6.4 Observability Stack

**OpenTelemetry** — installed via the `opentelemetry-operator` Helm chart. A single `OpenTelemetryCollector` CR in `Deployment` mode (with a `DaemonSet` sidecar for node-level metrics) receives OTLP from app SDKs and from Knative's tracing exporter, then fans out:

```
OTLP (gRPC :4317 / HTTP :4318)
        │
        ▼
  OTel Collector ──► Prometheus  (metrics, via /metrics scrape)
                ──► Tempo/Zipkin (traces — Tempo in cloud, in-cluster Zipkin locally)
                ──► Loki         (optional, logs — out of scope for the demo)
```

**Prometheus** — `kube-prometheus-stack` Helm chart, scrape interval `15s`, retention `2h` locally / `7d` in cloud. `ServiceMonitor`s are pre-created for `knative-serving`, `knative-eventing`, `kourier`, the OTel Collector and the Astronomy Shop services.

**Grafana** — bundled with `kube-prometheus-stack`, exposed via a `Service` of type `LoadBalancer` (cloud) or `port-forward` (local). Dashboards are provisioned from ConfigMaps:
- `knative-extensions/monitoring` — Knative Serving, Eventing, Control Plane.
- `opentelemetry-demo/grafana` — Astronomy Shop business metrics.
- Custom panels for the demo: *Revision traffic share*, *Cold-start latency*, *Active pods per revision*.

Default credentials are rotated at bootstrap and stored as a Kubernetes `Secret` (`grafana-admin`); the value is printed by the bootstrap script.

### 6.5 LLM / MCP Configuration

`kubernetes-mcp-server` runs as a `Deployment` in the `mcp` namespace with a dedicated `ServiceAccount` bound to a least-privilege `ClusterRole` (read everywhere, write only in `astronomy-shop` and on `knative.dev` / `serving.knative.dev` resources). The LangChain runner connects over stdio for local demo or over SSE when the LLM lives in a hosted IDE (Cursor / Claude Desktop).

Environment variables consumed by the runner:

| Variable | Purpose |
|----------|---------|
| `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` | LLM provider credentials |
| `MCP_SERVER_URL` | URL or stdio command of the MCP server |
| `KUBECONFIG` | Path to a kubeconfig limited to the demo cluster |
| `DEMO_NAMESPACE` | `astronomy-shop` — guard-rail for write operations |
| `LANGCHAIN_TRACING_V2` / `LANGCHAIN_API_KEY` | Optional: capture agent traces in LangSmith for the report |

A small system prompt pins the LLM to: Knative APIs only, the demo namespace, a refusal policy for destructive cluster-wide actions, and a requirement to echo the YAML it is about to apply before applying it (so the operator can veto).

### 6.6 Networking

- **Local:** Kourier on NodePort, exposed by `kind` port-mapping `80→31080`, `443→31443`; magic DNS `*.127.0.0.1.nip.io` resolves to the kind node.
- **Cloud:** Kourier on a cloud LoadBalancer; a wildcard DNS record (`*.demo.example.com`) points at the LB; cert-manager issues a Let's Encrypt wildcard via DNS-01.
- **Egress:** the cluster must reach `api.anthropic.com` / `api.openai.com` and the container registries used by the Astronomy Shop. No inbound from the public internet is required in the local variant.

### 6.7 Secrets and Configuration Management

All secrets (LLM API keys, Grafana admin password, OTel exporter tokens) are loaded from a single `.env` file at bootstrap time and rendered into Kubernetes `Secret`s by the install script. The `.env` file is `.gitignore`'d; an `.env.example` documents every required variable. No secret is committed to the repository.

### 6.8 Reproducibility

The whole environment is described by:

```
deploy/
  kind-config.yaml              # local cluster shape
  knative/                      # KnativeServing + KnativeEventing CRs
  observability/                # otel-collector.yaml, prometheus-values.yaml, grafana-dashboards/
  mcp/                          # RBAC, Deployment, Service for MCP Server
  astronomy-shop/               # patched manifests with Knative Services
scripts/
  bootstrap.sh                  # idempotent installer: kind → knative → obs → mcp → app
  teardown.sh                   # deletes the kind cluster (or namespaces, in cloud)
```

Running `./scripts/bootstrap.sh` from a clean machine yields the demo environment described above; `./scripts/teardown.sh` returns the host to its initial state.

---

## 7. Installation Method

---

## 8. Demo Deployment Steps

### 8a. Configuration Setup

### 8b. Data Preparation

---

## 9. Demo Description

### 9a. Execution Procedure

### 9b. Results Presentation

---

## 10. Summary and Conclusions

---

## 11. References

### Knative
- https://knative.dev/
- https://knative.dev/docs/serving/
- https://knative.dev/docs/eventing/
- https://knative.dev/blog/articles/distributed-tracing/
- https://knative.dev/docs/serving/observability/metrics/collecting-metrics/

### OpenTelemetry
- https://opentelemetry.io/
- https://opentelemetry.io/blog/2022/knative/

### Prometheus & Grafana
- https://prometheus.io/
- https://grafana.com/
- https://github.com/knative-extensions/monitoring
- https://github.com/prometheus-community/helm-charts

### LLM, LangChain, MCP
- https://docs.langchain.com/
- https://docs.langchain.com/oss/python/langchain/mcp
- https://github.com/containers/kubernetes-mcp-server

### Demo Applications
- https://github.com/open-telemetry/opentelemetry-demo
- https://github.com/GoogleCloudPlatform/microservices-demo
- https://github.com/wearearima/knative-demo
- https://github.com/pavolloffay/knative-tracing
