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

# At least one LLM key must be present, and it must match the chosen model.
LLM_MODEL="${LLM_MODEL:-gpt-4o}"
case "${LLM_MODEL}" in
  claude*|anthropic*)
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] || \
      fail "LLM_MODEL='${LLM_MODEL}' needs ANTHROPIC_API_KEY in .env (you can also switch LLM_MODEL to e.g. gpt-4o if you only have OPENAI_API_KEY)"
    ;;
  gpt*|o1*|o3*|openai*)
    [[ -n "${OPENAI_API_KEY:-}" ]] || \
      fail "LLM_MODEL='${LLM_MODEL}' needs OPENAI_API_KEY in .env"
    ;;
  *)
    if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" ]]; then
      fail "Neither ANTHROPIC_API_KEY nor OPENAI_API_KEY is set in .env"
    fi
    warn "Unknown LLM_MODEL='${LLM_MODEL}' — proceeding, but verify the SDK supports it"
    ;;
esac

# Webhook token must not be the default — it's the only authentication on /alerts.
if [[ "${WEBHOOK_TOKEN:-}" == "change-me-to-a-random-string" || -z "${WEBHOOK_TOKEN:-}" ]]; then
  fail "WEBHOOK_TOKEN must be set to a non-default value in .env"
fi

if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  warn "GRAFANA_ADMIN_PASSWORD is empty — Grafana will be installed with a random password"
fi

ok "Preflight passed"
