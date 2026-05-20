# Astronomy Shop overlay

This overlay deploys the [OpenTelemetry Astronomy Shop](https://github.com/open-telemetry/opentelemetry-demo)
into the `astronomy-shop` namespace, with **selected services converted
from `Deployment` to Knative `Service`** so we can demonstrate scale-to-zero
and traffic splitting (see §3.2 of the project README).

`base.yaml` is **not committed** — it is fetched by `scripts/bootstrap.sh`
from the upstream release matching `ASTRONOMY_SHOP_VERSION` in `.env`. This
keeps the upstream license/notices intact and lets us bump the demo by
changing one env var.

## Layout

```
deploy/astronomy-shop/
  kustomization.yaml       # bundles base + patches
  namespace.yaml
  base.yaml                # fetched at bootstrap time (gitignored)
  patches/
    frontend-knative.yaml  # convert frontend Deployment → knative Service
    # TODO: productcatalog, recommendation, currency, payment
```

## Services we Knative-ize

| Service | Why |
|---------|-----|
| `frontend` | User-facing, ideal for cold-start and canary demos. |
| `productcatalog` | Read-heavy, good autoscaling target. |
| `recommendation` | Used for traffic-split (90/10) in scenario #2. |
| `currency` | Stateless price conversion; cheap to scale to zero. |
| `payment` | Used to demonstrate diagnostics on synthetic failures. |

Stateful components (`kafka`, `valkey`, `postgres`, `flagd`) stay as
regular Deployments — Knative Serving is not suitable for stateful
workloads.
