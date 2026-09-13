#!/usr/bin/env bash
set -euo pipefail

# Conexao Azul wrapper for Blue MCP efficiency offline validation.
# Policy, tests and metrics contract live in BlueApps19; this runner only
# executes the mounted ACT workflow against an exact checkout.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ACT_BIN="${ACT_BIN:-${ACT_ROOT}/dist/local/act}"
BLUEAPPS_DIR="${BLUEAPPS_DIR:-${1:-${ACT_ROOT}/../BlueApps19}}"
WORKFLOW="${BLUE_MCP_EFFICIENCY_WORKFLOW:-ci/act/blue-mcp-efficiency.yml}"

if [[ ! -d "${BLUEAPPS_DIR}/.git" ]]; then
  echo "BLUE_MCP_EFFICIENCY_ACT_INVALID: BlueApps19 git checkout not found at ${BLUEAPPS_DIR}" >&2
  exit 2
fi

if [[ ! -f "${BLUEAPPS_DIR}/${WORKFLOW}" ]]; then
  echo "BLUE_MCP_EFFICIENCY_ACT_INVALID: workflow not found: ${BLUEAPPS_DIR}/${WORKFLOW}" >&2
  exit 2
fi

if [[ ! -x "${ACT_BIN}" ]]; then
  echo "Blue MCP efficiency: act binary missing; building fork with make build" >&2
  (cd "${ACT_ROOT}" && make build)
fi

if [[ ! -x "${ACT_BIN}" ]]; then
  echo "BLUE_MCP_EFFICIENCY_ACT_INVALID: act binary unavailable at ${ACT_BIN}" >&2
  exit 2
fi

CALLER_SHA="$(git -C "${BLUEAPPS_DIR}" rev-parse HEAD)"
if [[ ! "${CALLER_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "BLUE_MCP_EFFICIENCY_ACT_INVALID: unable to resolve exact BlueApps19 HEAD" >&2
  exit 2
fi

if [[ -n "$(git -C "${BLUEAPPS_DIR}" status --porcelain)" ]]; then
  echo "BLUE_MCP_EFFICIENCY_ACT_INVALID: BlueApps19 checkout must be clean" >&2
  exit 2
fi

echo "Blue MCP efficiency local preflight"
echo "  engine: conexaoazul/act"
echo "  repo:   ${BLUEAPPS_DIR}"
echo "  sha:    ${CALLER_SHA}"
echo "  flow:   ${WORKFLOW}"
echo "  safety: offline validation only; no Odoo runtime, provider call, merge, deploy or production mutation"

cd "${BLUEAPPS_DIR}"
exec "${ACT_BIN}" workflow_dispatch --bind -W "${WORKFLOW}" "${@:2}"
