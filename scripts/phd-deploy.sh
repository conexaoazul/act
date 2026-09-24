#!/usr/bin/env bash
set -euo pipefail

SERVICE="${PHD_SERVICE:-odoo-demo-phd-transporte}"
DB="${PHD_DB:-phd_demo}"
ADDONS="/usr/lib/python3/dist-packages/odoo/addons,/opt/odoo-enterprise,/opt/blue-addons"
UPGRADE="blue_custom_contracts,blue_custom_contracts_dynamic,blue_custom_hr_employee,blue_hr_employee_medical,blue_phd_documents"
INSTALL="blue_whatsapp_custom_contracts,blue_whatsapp_custom_contracts_dynamic"
BACKUP_ROOT="${PHD_BACKUP_ROOT:-$HOME/phd-backups}"
HEALTHCHECK="${PHD_HEALTHCHECK:-/usr/local/bin/phd-healthcheck}"
IMAGE=""
APPLY=0

usage() {
  cat <<EOF
Uso:
  phd-deploy --image ghcr.io/conexaoazul/odoo-demo-phd:<tag> --apply
  phd-deploy --image ...            # preflight + gate no clone, sem produção

O script:
  1) checa saúde;
  2) puxa e valida a imagem;
  3) clona o banco e executa upgrade/install;
  4) em --apply faz backup;
  5) rollout start-first com rollback automático;
  6) upgrade real;
  7) refresh de registry e smoke test.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Argumento desconhecido: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$IMAGE" ]] || { echo "Falta --image" >&2; exit 2; }
[[ "$IMAGE" == ghcr.io/conexaoazul/odoo-demo-phd:* ]] || { echo "Imagem fora do repositório permitido" >&2; exit 2; }

command -v docker >/dev/null
command -v curl >/dev/null

echo "== PRECHECK =="
"$HEALTHCHECK" || { echo "Precheck crítico falhou; deploy bloqueado." >&2; exit 10; }

echo "== IMAGE =="
docker pull "$IMAGE" >/dev/null
for m in blue_custom_contracts blue_custom_contracts_dynamic blue_custom_hr_employee blue_hr_employee_medical blue_whatsapp_custom_contracts blue_whatsapp_custom_contracts_dynamic; do
  docker run --rm --entrypoint sh "$IMAGE" -c "test -f /opt/blue-addons/$m/__manifest__.py"
done
echo "Imagem contém os addons esperados."

cid=$(docker ps --filter "label=com.docker.swarm.service.name=$SERVICE" -q | head -1)
[[ -n "$cid" ]] || { echo "Container PHD não encontrado" >&2; exit 11; }
dbhost=$(docker exec "$cid" sh -lc 'printf %s "$HOST"')
dbport=$(docker exec "$cid" sh -lc 'printf %s "${PORT:-5432}"')
dbuser=$(docker exec "$cid" sh -lc 'printf %s "$USER"')
dbpass=$(docker exec "$cid" sh -lc 'cat "$PASSWORD_FILE"')
clone="gate_phd_demo_$(date +%Y%m%d%H%M%S)"

cleanup() {
  docker exec -e PGPASSWORD="$dbpass" "$cid" psql -h "$dbhost" -p "$dbport" -U "$dbuser" -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $clone WITH (FORCE)" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== CLONE GATE: $clone =="
docker exec -e PGPASSWORD="$dbpass" "$cid" psql -h "$dbhost" -p "$dbport" -U "$dbuser" -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE $clone OWNER $dbuser" >/dev/null
docker exec "$cid" sh -lc 'PW=$(cat "$PASSWORD_FILE"); export PGPASSWORD="$PW"; pg_dump -h "$HOST" -p "${PORT:-5432}" -U "$USER" -d phd_demo --no-owner --no-acl' \
  | sed '/transaction_timeout/d' \
  | docker exec -i -e PGPASSWORD="$dbpass" "$cid" psql -h "$dbhost" -p "$dbport" -U "$dbuser" -d "$clone" -v ON_ERROR_STOP=1 -q

gate_log=$(mktemp)
if ! docker run --rm --entrypoint odoo "$IMAGE" \
  -d "$clone" -u "$UPGRADE" -i "$INSTALL" \
  --db_host "$dbhost" --db_port "$dbport" --db_user "$dbuser" --db_password "$dbpass" \
  --addons-path "$ADDONS" --stop-after-init --no-http --log-level=warn >"$gate_log" 2>&1; then
  tail -120 "$gate_log" >&2
  echo "Gate Odoo reprovado. Produção intacta." >&2
  exit 20
fi
if grep -Eq 'CRITICAL|Traceback|Failed to initialize|incompatible version|not installable|ParseError' "$gate_log"; then
  tail -120 "$gate_log" >&2
  echo "Gate Odoo encontrou erro crítico. Produção intacta." >&2
  exit 21
fi

states=$(docker exec -e PGPASSWORD="$dbpass" "$cid" psql -h "$dbhost" -p "$dbport" -U "$dbuser" -d "$clone" -t -A -c "select count(*) from ir_module_module where name = any(ARRAY['blue_custom_contracts','blue_custom_contracts_dynamic','blue_custom_hr_employee','blue_hr_employee_medical','blue_phd_documents','blue_whatsapp_custom_contracts','blue_whatsapp_custom_contracts_dynamic']) and state='installed'")
[[ "$states" == "7" ]] || { echo "Gate: apenas $states/7 módulos installed" >&2; exit 22; }
echo "GATE_PASS: 7/7 módulos installed no clone."

if (( APPLY == 0 )); then
  echo "DRY_RUN_OK: use --apply para promover a mesma imagem."
  exit 0
fi

mkdir -p "$BACKUP_ROOT"
stamp=$(date +%Y%m%d-%H%M%S)
backup="$BACKUP_ROOT/phd_demo-predeploy-$stamp.dump"
spec="$BACKUP_ROOT/$SERVICE-predeploy-$stamp.json"

echo "== BACKUP =="
docker exec "$cid" sh -lc 'PW=$(cat "$PASSWORD_FILE"); export PGPASSWORD="$PW"; pg_dump -h "$HOST" -p "${PORT:-5432}" -U "$USER" -d phd_demo -Fc --no-owner --no-acl' >"$backup"
test -s "$backup"
sha256sum "$backup" | tee "$backup.sha256"
docker service inspect "$SERVICE" >"$spec"
echo "Backup: $backup"

previous=$(docker service inspect "$SERVICE" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')
echo "== ROLLOUT =="
echo "Anterior: $previous"
docker service update --image "$IMAGE" --update-order start-first --update-parallelism 1 --update-failure-action rollback --update-monitor 20s --detach=false "$SERVICE"

cid=$(docker ps --filter "label=com.docker.swarm.service.name=$SERVICE" -q | head -1)
dbhost=$(docker exec "$cid" sh -lc 'printf %s "$HOST"')
dbport=$(docker exec "$cid" sh -lc 'printf %s "${PORT:-5432}"')
dbuser=$(docker exec "$cid" sh -lc 'printf %s "$USER"')
dbpass=$(docker exec "$cid" sh -lc 'cat "$PASSWORD_FILE"')

echo "== PROD UPGRADE =="
prod_log=$(mktemp)
if ! docker run --rm --entrypoint odoo "$IMAGE" \
  -d "$DB" -u "$UPGRADE" -i "$INSTALL" \
  --db_host "$dbhost" --db_port "$dbport" --db_user "$dbuser" --db_password "$dbpass" \
  --addons-path "$ADDONS" --stop-after-init --no-http --log-level=warn >"$prod_log" 2>&1; then
  tail -160 "$prod_log" >&2
  echo "ATENÇÃO: upgrade real falhou. Backup preservado em $backup. Não restaure automaticamente." >&2
  exit 30
fi
if grep -Eq 'CRITICAL|Traceback|Failed to initialize|incompatible version|not installable|ParseError' "$prod_log"; then
  tail -160 "$prod_log" >&2
  echo "ATENÇÃO: log crítico no upgrade real. Backup preservado em $backup." >&2
  exit 31
fi

echo "== REGISTRY REFRESH =="
docker service update --force --update-order start-first --update-failure-action rollback --update-monitor 20s --detach=false "$SERVICE"

echo "== FINAL CHECK =="
"$HEALTHCHECK"
echo "DEPLOY_OK image=$IMAGE backup=$backup"
