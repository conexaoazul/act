#!/usr/bin/env bash
set -euo pipefail

APPLY=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if (( APPLY )); then
  CMD=deploy
else
  CMD=gate
fi

exec /usr/local/bin/odoo-blueops \
  --config /etc/blueops/odoo/phd.env \
  "$CMD" "${ARGS[@]}"
