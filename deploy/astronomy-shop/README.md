# Astronomy Shop overlay

Deploys the [OpenTelemetry Astronomy Shop](https://github.com/open-telemetry/opentelemetry-demo)
into the `astronomy-shop` namespace using the **official Helm chart**
(`open-telemetry/opentelemetry-demo`, pinned by `OTEL_DEMO_CHART_VERSION`
in `.env`).

We use the chart rather than the rendered `kubernetes/opentelemetry-demo.yaml`
because the rendered manifest hardcodes the `otel-demo` namespace and bundles a
full second observability stack. `values.yaml` here disables the duplicate
Grafana and OpenSearch and keeps the app's own Collector + Jaeger + Prometheus
so the chart's collector config stays valid.

The app installs as ordinary `Deployment`s. **Converting a service to a Knative
Service is the LLM agent's job** (demo scenario #1); `knative/frontend.yaml` is
the reference manifest the agent should produce and a manual fallback.

## Layout

```
deploy/astronomy-shop/
  values.yaml            # Helm values (disable duplicate backends)
  knative/
    frontend.yaml        # reference Knative Service (NOT auto-applied)
  README.md
```

## Real upstream names (verified against chart appVersion 2.2.0)

Inter-service addresses use port **8080** and these Deployment/Service names:

| Role | Name |
|------|------|
| Web UI | `frontend` (behind `frontend-proxy`, the Envoy entrypoint) |
| Catalog | `product-catalog` |
| Recommendations | `recommendation` |
| Currency | `currency` |
| Payment | `payment` |
| Cart store | `valkey-cart` |
| Orders DB | `postgresql` |
| Feature flags | `flagd` |
| Telemetry sink | `otel-collector` |

Stateful components (`valkey-cart`, `postgresql`, `kafka`, `flagd`) stay as
Deployments — Knative Serving is not for stateful workloads.

## Caveat when Knative-izing internal services

Knative cluster-local Services answer on **port 80**, but Astronomy Shop
services call each other on **:8080**. Convert a **leaf** service that nothing
else calls first (`currency` is the easiest), or access a converted service
through Kourier rather than the in-cluster mesh. See the header of
`knative/frontend.yaml`.
