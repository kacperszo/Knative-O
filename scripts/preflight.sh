#!/usr/bin/env bash
# Phase 0: verify tools and .env before touching the cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_env

info "Phase 0: preflight"

case "${DEPLOY_TARGET:-local}" in
  local)
    require_tools docker kind kubectl helm
    ;;
  cloud)
    require_tools kubectl helm
    [[ -n "${KUBECONFIG:-}" ]] || warn "KUBECONFIG not set; relying on default ~/.kube/config"
    ;;
  *)
    fail "DEPLOY_TARGET must be 'local' or 'cloud' (got: ${DEPLOY_TARGET:-})"
    ;;
esac

# At least one LLM key must be present.
if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" ]]; then
  fail "Neither ANTHROPIC_API_KEY nor OPENAI_API_KEY is set in .env"
fi

# Webhook token must not be the default — it's the only authentication on /alerts.
if [[ "${WEBHOOK_TOKEN:-}" == "change-me-to-a-random-string" || -z "${WEBHOOK_TOKEN:-}" ]]; then
  fail "WEBHOOK_TOKEN must be set to a non-default value in .env"
fi

if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  warn "GRAFANA_ADMIN_PASSWORD is empty — Grafana will be installed with a random password"
fi

ok "Preflight passed"
