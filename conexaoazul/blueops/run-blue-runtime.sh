#!/usr/bin/env bash
set -euo pipefail

# Conexao Azul integration wrapper for the local GitHub Actions runner.
# It intentionally delegates Odoo/Blue Runtime rules to BlueApps19 and keeps
# this act fork as the execution engine only.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ACT_BIN="${ACT_BIN:-${ACT_ROOT}/dist/local/act}"
BLUEAPPS_DIR="${BLUEAPPS_DIR:-${1:-${ACT_ROOT}/../BlueApps19}}"
WORKFLOW="${BLUE_RUNTIME_WORKFLOW:-.github/workflows/blue-runtime-local-preflight.yml}"

if [[ ! -d "${BLUEAPPS_DIR}/.git" ]]; then
  echo "BLUEOPS_ACT_INVALID: BlueApps19 git checkout not found at ${BLUEAPPS_DIR}" >&2
  exit 2
fi

if [[ ! -f "${BLUEAPPS_DIR}/${WORKFLOW}" ]]; then
  echo "BLUEOPS_ACT_INVALID: workflow not found: ${BLUEAPPS_DIR}/${WORKFLOW}" >&2
  exit 2
fi

if [[ ! -x "${ACT_BIN}" ]]; then
  echo "BlueOps: act binary missing; building fork with make build" >&2
  (cd "${ACT_ROOT}" && make build)
fi

if [[ ! -x "${ACT_BIN}" ]]; then
  echo "BLUEOPS_ACT_INVALID: act binary still unavailable at ${ACT_BIN}" >&2
  exit 2
fi

CALLER_SHA="$(git -C "${BLUEAPPS_DIR}" rev-parse HEAD)"
if [[ ! "${CALLER_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "BLUEOPS_ACT_INVALID: unable to resolve exact BlueApps19 HEAD" >&2
  exit 2
fi

echo "BlueOps local preflight"
echo "  engine: conexaoazul/act"
echo "  repo:   ${BLUEAPPS_DIR}"
echo "  sha:    ${CALLER_SHA}"
echo "  flow:   ${WORKFLOW}"
echo "  safety: evidence-only; no merge/deploy/production authorization"

cd "${BLUEAPPS_DIR}"
exec "${ACT_BIN}" workflow_dispatch -W "${WORKFLOW}" "${@:2}"
