#!/usr/bin/env bash
set -euo pipefail
exec /usr/local/bin/odoo-blueops --config /etc/blueops/odoo/phd.env deploy "$@"
