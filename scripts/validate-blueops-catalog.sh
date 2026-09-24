#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-config/odoo}"
shopt -s nullglob
count=0
for cfg in "$ROOT"/*.env; do
  env="$(basename "$cfg" .env)"
  [[ "$env" == "example" ]] && continue
  BLUEOPS_CONFIG_ROOT="$ROOT" BLUEOPS_ODOO_CORE=/bin/true "$(dirname "$0")/blueops" env validate "$env"
  count=$((count+1))
done
echo "CATALOG_OK environments=$count"
