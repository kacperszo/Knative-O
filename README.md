# Knative-O — Serverless Application Observability (Project Type 1)

**Authors:**
- [Name Surname 1]
- [Name Surname 2]
- [Name Surname 3]
- [Name Surname 4]

**Programme:** Computer Science, MSc, Semester 1

---

## 📝 Project Description

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

---

## 3. Case Study Concept

### 🎯 Project Goals

- **LLM-driven Knative management:** Deploy and configure serverless applications using natural-language prompts instead of manual YAML/kubectl.
- **Full observability pipeline:** Instrument the application with OpenTelemetry, collect metrics with Prometheus, visualize with Grafana.
- **Verify LLM operations through observability:** Use dashboards to confirm that LLM-driven deployments, scaling changes, and traffic splits work correctly.

### Planned Demonstration Scenarios

1. **Deployment via LLM** — the user describes services to deploy; the LLM generates and applies Knative manifests through the MCP Server.
2. **Revision & traffic management** — the LLM creates a new service version and sets up a canary deployment (e.g. 90/10 traffic split).
3. **Autoscaling configuration** — the LLM adjusts scale-to-zero timeout, concurrency limits, and min/max replicas.
4. **Observability verification** — Grafana dashboards show how Knative metrics respond to LLM-driven operations.
5. **Diagnostics** — the LLM reads pod status, Kubernetes events, and logs to identify issues.

### Demo Application — Candidates

1. **OpenTelemetry Astronomy Shop** (https://github.com/open-telemetry/opentelemetry-demo)
   — 11+ microservices, native OTel instrumentation, built-in Prometheus & Grafana, load generator. **Best candidate.**

2. **Google Online Boutique** (https://github.com/GoogleCloudPlatform/microservices-demo)
   — 11 microservices (gRPC), runs on any K8s cluster, needs OTel instrumentation added. **Good candidate.**

3. **Knative Eventing Demo** (https://github.com/wearearima/knative-demo)
   — Spring Boot + Kafka, native Knative Eventing integration. **Good candidate.**

4. **Knative Tracing Demo** (https://github.com/pavolloffay/knative-tracing)
   — Go + Java apps with CloudEvents, excellent distributed tracing demonstration. **Good candidate.**

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

## 6. Environment Configuration

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

---

## Project Repository

> *Repository link: [To be added]*

```
knative-o/
├── README.md              # Project documentation
├── k8s/                   # Kubernetes/Knative manifests
├── otel/                  # OpenTelemetry Collector config
├── monitoring/            # Prometheus + Grafana config
├── mcp/                   # MCP Server + LangChain setup
├── scripts/               # Installation scripts
└── dashboards/            # Grafana dashboards
```
