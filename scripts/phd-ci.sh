#!/usr/bin/env bash
set -euo pipefail

REF="${1:-19.0-mod}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TOKEN="${BLUE_CI_GIT_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
URL="https://github.com/conexaoazul/BlueApps19.git"

if [[ -n "$TOKEN" ]]; then
  ASK="$TMP/askpass.sh"
  cat >"$ASK" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *) printf '%s\n' "${BLUE_CI_GIT_TOKEN:?}" ;;
esac
EOF
  chmod 700 "$ASK"
  BLUE_CI_GIT_TOKEN="$TOKEN" GIT_ASKPASS="$ASK" GIT_TERMINAL_PROMPT=0     git clone --depth 50 --branch "$REF" "$URL" "$TMP/repo"
else
  GIT_TERMINAL_PROMPT=0 git clone --depth 50 --branch "$REF" "$URL" "$TMP/repo"
fi

cd "$TMP/repo"
python3 scripts/qa_phd_whatsapp_dynamic_static.py
for module in   blue_custom_contracts   blue_custom_contracts_dynamic   blue_custom_hr_employee   blue_hr_employee_medical   blue_phd_documents   blue_whatsapp_custom_contracts   blue_whatsapp_custom_contracts_dynamic
do
  python3 scripts/validate_odoo_module.py "$module"
done

echo "PHD_CI=PASS ref=$REF sha=$(git rev-parse HEAD)"
