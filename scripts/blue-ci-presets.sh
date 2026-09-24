#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/blue-ci-presets.sh <preset> [-- act args...]

Presets:
  phd-suite          Validate PHD Odoo 19 modules
  blue-smart-pricing Validate Blue Smart Pricing on BlueApps19
EOF
}

[[ $# -ge 1 ]] || { usage; exit 2; }
PRESET="$1"
shift
[[ "${1:-}" == "--" ]] && shift || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$PRESET" in
  phd-suite)
    exec "$SCRIPT_DIR/phd-ci.sh" "${BLUE_CI_REF:-19.0-mod}"
    ;;
  blue-smart-pricing)
    REPO_URL="https://github.com/ConexaoAzulDigital/BlueApps19.git"
    REF="19.0"
    WORKFLOW=".act/workflows/blue-smart-pricing.yml"
    ;;
  *)
    echo "Unknown preset: $PRESET" >&2
    usage >&2
    exit 2
    ;;
esac

exec "$SCRIPT_DIR/blue-ci.sh" \
  "$REPO_URL" \
  "$REF" \
  "$WORKFLOW" \
  workflow_dispatch \
  -- "$@"
