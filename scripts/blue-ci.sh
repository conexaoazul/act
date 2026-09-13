#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/blue-ci.sh <repo-url> <ref> <workflow-path> [event] [-- act args...]

Example:
  scripts/blue-ci.sh \
    https://github.com/ConexaoAzulDigital/BlueApps19.git \
    19.0 \
    .act/workflows/blue-smart-pricing.yml \
    workflow_dispatch

The target repository is cloned into a temporary directory and executed with
this fork's act binary. GitHub Actions does not need to be available.
EOF
}

[[ $# -ge 3 ]] || { usage; exit 2; }
REPO_URL="$1"
REF="$2"
WORKFLOW="$3"
EVENT="${4:-workflow_dispatch}"
if [[ $# -ge 4 ]]; then shift 4; else shift 3; fi
[[ "${1:-}" == "--" ]] && shift || true

ACT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACT_BIN="${ACT_BIN:-$ACT_ROOT/dist/blue-act}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$ACT_BIN" ]]; then
  mkdir -p "$(dirname "$ACT_BIN")"
  (cd "$ACT_ROOT" && go build -o "$ACT_BIN" ./cmd/act)
fi

git clone --depth 1 --branch "$REF" "$REPO_URL" "$TMP/repo"

exec "$ACT_BIN" \
  --directory "$TMP/repo" \
  --workflows "$TMP/repo/$WORKFLOW" \
  "$EVENT" \
  "$@"
