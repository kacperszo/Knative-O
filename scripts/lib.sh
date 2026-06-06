# shellcheck shell=bash
# Common helpers sourced by bootstrap.sh / teardown.sh / smoke.sh.

set -euo pipefail

# Resolve repo root from the script that sourced us.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")/.." && pwd)"
DEPLOY_DIR="${REPO_ROOT}/deploy"

if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""; C_OFF=""
fi

log()   { printf "%s[%(%H:%M:%S)T]%s %s\n" "${C_DIM}" -1 "${C_OFF}" "$*"; }
info()  { printf "%s[%(%H:%M:%S)T] %s%s\n" "${C_BLUE}" -1 "$*" "${C_OFF}"; }
ok()    { printf "%s[%(%H:%M:%S)T] %s%s\n" "${C_GREEN}" -1 "$*" "${C_OFF}"; }
warn()  { printf "%s[%(%H:%M:%S)T] %s%s\n" "${C_YELLOW}" -1 "$*" "${C_OFF}" >&2; }
fail()  { printf "%s[%(%H:%M:%S)T] %s%s\n" "${C_RED}" -1 "$*" "${C_OFF}" >&2; exit 1; }

# Load .env if present, exporting variables.
load_env() {
  local env_file="${REPO_ROOT}/.env"
  if [[ -f "${env_file}" ]]; then
    set -a; source "${env_file}"; set +a
  else
    warn ".env not found at ${env_file} — falling back to .env.example defaults"
    set -a; source "${REPO_ROOT}/.env.example"; set +a
  fi
}

require_tools() {
  local missing=()
  for t in "$@"; do
    command -v "${t}" >/dev/null 2>&1 || missing+=("${t}")
  done
  if (( ${#missing[@]} > 0 )); then
    fail "Missing required tools: ${missing[*]}"
  fi
}

# kubectl wait that retries until a CRD is Established (no point applying CRs
# referencing a CRD that the API server hasn't accepted yet).
wait_crd_established() {
  local crd="$1"
  local timeout="${2:-120s}"
  kubectl wait --for=condition=Established "crd/${crd}" --timeout="${timeout}"
}

wait_rollout() {
  local kind="$1" name="$2" ns="$3" timeout="${4:-180s}"
  kubectl rollout status -n "${ns}" "${kind}/${name}" --timeout="${timeout}"
}

wait_condition() {
  local kind="$1" name="$2" ns="$3" cond="$4" timeout="${5:-300s}"
  kubectl wait -n "${ns}" "${kind}/${name}" --for=condition="${cond}" --timeout="${timeout}"
}

# Echo "--version X" when the given value is non-empty, otherwise nothing
# (so Helm resolves the latest chart version). Lets us avoid shipping hard
# pins that may 404 if a patch release is pulled.
version_flag() {
  local v="${1:-}"
  [[ -n "${v}" ]] && printf -- "--version %s" "${v}"
}
