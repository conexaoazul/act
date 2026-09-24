#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_BIN="${DEST_BIN:-/usr/local/bin}"
DEST_ETC="${DEST_ETC:-/etc/blueops/odoo}"
STATE_ROOT="${STATE_ROOT:-/var/lib/blueops}"

need_root() {
  [[ "$(id -u)" == "0" ]] || { echo "Execute com sudo/root." >&2; exit 2; }
}

need_root
install -d -m 0755 "$DEST_BIN" "$DEST_ETC"
install -d -m 2770 -o root -g docker "$STATE_ROOT" "$STATE_ROOT/locks" "$STATE_ROOT/backups"
install -m 0755 "$ROOT/scripts/odoo-blueops.sh" "$DEST_BIN/odoo-blueops"
install -m 0755 "$ROOT/scripts/blueops" "$DEST_BIN/blueops"
install -m 0755 "$ROOT/scripts/phd-deploy.sh" "$DEST_BIN/phd-deploy"
install -m 0755 "$ROOT/scripts/phd-healthcheck.sh" "$DEST_BIN/phd-healthcheck"
for cfg in "$ROOT"/config/odoo/*.env; do
  name="$(basename "$cfg")"
  [[ "$name" == "example.env" ]] && continue
  install -m 0644 "$cfg" "$DEST_ETC/$name"
done

echo "BlueOps instalado."
echo "Teste: sudo -u <usuario-docker> $DEST_BIN/blueops env list"
echo "Health PHD: sudo -u <usuario-docker> $DEST_BIN/blueops odoo phd check"
