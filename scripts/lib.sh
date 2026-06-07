# shellcheck shell=bash
# Common helpers sourced by bootstrap.sh / teardown.sh / smoke.sh.

set -euo pipefail

# Resolve repo root by walking up from the sourcing script until we hit a
# Makefile. Doing `dirname .. && pwd` only works for one level up — it broke
# when sourced from scripts/scenarios/*.sh, where REPO_ROOT pointed at
# scripts/ instead of the repo root and the .env lookup failed.
_find_repo_root() {
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[2]:-${BASH_SOURCE[1]:-$0}}")" && pwd)"
  while [[ "${d}" != "/" ]]; do
    [[ -f "${d}/Makefile" ]] && { echo "${d}"; return 0; }
    d="$(dirname "${d}")"
  done
  return 1
}
REPO_ROOT="$(_find_repo_root)" || { echo "lib.sh: cannot find repo root" >&2; exit 1; }
DEPLOY_DIR="${REPO_ROOT}/deploy"

if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""; C_OFF=""
fi

# NB: avoid printf's %(...)T format — it needs bash >= 4.2 and macOS still
# ships bash 3.2. `date` once per log line is fine for a bootstrap script.
_ts() { date +%H:%M:%S; }
log()   { printf "%s[%s]%s %s\n" "${C_DIM}"    "$(_ts)" "${C_OFF}" "$*"; }
info()  { printf "%s[%s] %s%s\n" "${C_BLUE}"   "$(_ts)" "$*" "${C_OFF}"; }
ok()    { printf "%s[%s] %s%s\n" "${C_GREEN}"  "$(_ts)" "$*" "${C_OFF}"; }
warn()  { printf "%s[%s] %s%s\n" "${C_YELLOW}" "$(_ts)" "$*" "${C_OFF}" >&2; }
fail()  { printf "%s[%s] %s%s\n" "${C_RED}"    "$(_ts)" "$*" "${C_OFF}" >&2; exit 1; }

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
