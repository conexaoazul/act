#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
BlueOps Odoo deploy tool

Uso:
  odoo-blueops --config /etc/blueops/odoo/phd.env check
  odoo-blueops --config /etc/blueops/odoo/phd.env gate --image <image>
  odoo-blueops --config /etc/blueops/odoo/phd.env deploy --image <image>

Comandos:
  check   valida Swarm, container, PostgreSQL, HTTP/TLS e estados transitórios
  gate    cria snapshot único, restaura clone e valida módulos sem tocar produção
  deploy  executa check + snapshot + clone gate + rollout + upgrade + refresh + check
EOF
}

CONFIG=""
CMD=""
IMAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    check|gate|deploy) CMD="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Argumento desconhecido: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$CONFIG" && -r "$CONFIG" ]] || { echo "Config ausente/ilegível: $CONFIG" >&2; exit 2; }
[[ -n "$CMD" ]] || { usage >&2; exit 2; }

# shellcheck disable=SC1090
source "$CONFIG"

: "${BLUEOPS_ENV:?}"
: "${SERVICE:?}"
: "${DB:?}"
: "${URL:?}"
: "${IMAGE_PREFIX:?}"
: "${ADDONS_PATH:?}"
: "${EXPECTED_MODULES:?}"
: "${BACKUP_ROOT:?}"

LOG_WINDOW="${LOG_WINDOW:-5m}"
UPDATE_MONITOR="${UPDATE_MONITOR:-20s}"
UPGRADE_MODULES="${UPGRADE_MODULES:-}"
INSTALL_MODULES="${INSTALL_MODULES:-}"

if [[ "$CMD" != "check" ]]; then
  [[ -n "$IMAGE" ]] || { echo "Falta --image" >&2; exit 2; }
  [[ "$IMAGE" == "$IMAGE_PREFIX"* ]] || { echo "Imagem fora do prefixo permitido: $IMAGE_PREFIX" >&2; exit 2; }
fi

LOCK="/tmp/blueops-odoo-${BLUEOPS_ENV}.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "Outro deploy/check exclusivo de ${BLUEOPS_ENV} já está em execução." >&2
  exit 9
fi

say(){ printf '%s\n' "$*"; }
ok(){ say "OK: $*"; }
fail(){ say "FAIL: $*" >&2; exit 1; }

cid() {
  docker ps --filter "label=com.docker.swarm.service.name=$SERVICE" -q | head -1
}

db_ctx() {
  CID="$(cid)"
  [[ -n "$CID" ]] || fail "container local do service não encontrado"
  DBHOST="$(docker exec "$CID" sh -lc 'printf %s "$HOST"')"
  DBPORT="$(docker exec "$CID" sh -lc 'printf %s "${PORT:-5432}"')"
  DBUSER="$(docker exec "$CID" sh -lc 'printf %s "$USER"')"
  DBPASS="$(docker exec "$CID" sh -lc 'cat "$PASSWORD_FILE"')"
}

check_current() {
  local replicas health http code tls elapsed transient recovery recent
  replicas="$(docker service ls --filter "name=$SERVICE" --format '{{.Replicas}}' | head -1)"
  [[ "$replicas" == "1/1" ]] || fail "Swarm replicas=$replicas"
  ok "Swarm $SERVICE $replicas"

  db_ctx
  health="$(docker inspect "$CID" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')"
  [[ "$health" == "healthy" || "$health" == "running" ]] || fail "container=$health"
  ok "container $health"

  local stable=0 sample
  for sample in 1 2 3; do
    recovery="$(docker exec "$CID" python3 - "$DB" <<'PY'
import os,pathlib,psycopg2,sys
db=sys.argv[1]
pw=pathlib.Path(os.environ["PASSWORD_FILE"]).read_text().strip()
try:
    c=psycopg2.connect(host=os.environ["HOST"],port=os.environ.get("PORT","5432"),user=os.environ["USER"],password=pw,dbname=db,connect_timeout=5)
    q=c.cursor(); q.execute("select pg_is_in_recovery()")
    print("t" if q.fetchone()[0] else "f")
    c.close()
except Exception:
    print("error")
PY
)"
    if [[ "$recovery" == "f" ]]; then
      stable=$((stable+1))
    else
      stable=0
    fi
    [[ "$stable" == "3" ]] && break
    sleep 2
  done
  [[ "$stable" == "3" ]] || fail "PostgreSQL sem estabilidade (último estado=$recovery)"
  ok "PostgreSQL estável: 3/3 amostras fora de recovery"

  transient="$(docker exec "$CID" python3 - "$DB" <<'PY'
import os,pathlib,psycopg2,sys
db=sys.argv[1]
pw=pathlib.Path(os.environ["PASSWORD_FILE"]).read_text().strip()
c=psycopg2.connect(host=os.environ["HOST"],port=os.environ.get("PORT","5432"),user=os.environ["USER"],password=pw,dbname=db,connect_timeout=5)
q=c.cursor()
q.execute("select count(*) from ir_module_module where state in ('to upgrade','to install','to remove')")
print(q.fetchone()[0]); c.close()
PY
)"
  [[ "$transient" == "0" ]] || fail "$transient módulos em estado transitório"
  ok "sem módulos em estado transitório"

  http="$(curl -sS -L -o /dev/null --max-time 15 -w '%{http_code}|%{ssl_verify_result}|%{time_total}' "$URL" || true)"
  IFS='|' read -r code tls elapsed <<<"$http"
  [[ "$code" == "200" ]] || fail "HTTP=$code"
  [[ "$tls" == "0" ]] || fail "TLS verify=$tls"
  ok "HTTP 200 / TLS válido (${elapsed}s)"

  recent="$(docker service logs --since "$LOG_WINDOW" --tail 1000 "$SERVICE" 2>&1 | grep -Ei 'CRITICAL|Failed to initialize database|incompatible version|not installable|database system is in recovery mode|Some modules have inconsistent states' | tail -20 || true)"
  [[ -z "$recent" ]] || { printf '%s\n' "$recent" >&2; fail "erros críticos recentes ($LOG_WINDOW)"; }
  ok "sem erros críticos recentes ($LOG_WINDOW)"
}

snapshot() {
  mkdir -p "$BACKUP_ROOT"
  STAMP="$(date +%Y%m%d-%H%M%S)"
  SNAPSHOT="$BACKUP_ROOT/${DB}-blueops-${STAMP}.dump"
  SPEC="$BACKUP_ROOT/${SERVICE}-${STAMP}.json"
  say "== SNAPSHOT =="
  local attempt log
  for attempt in 1 2 3; do
    log="$(mktemp)"
    if docker exec "$CID" sh -lc 'PW=$(cat "$PASSWORD_FILE"); export PGPASSWORD="$PW"; exec pg_dump -h "$HOST" -p "${PORT:-5432}" -U "$USER" -d '"$DB"' -Fc --no-owner --no-acl' >"$SNAPSHOT" 2>"$log"; then
      break
    fi
    cat "$log" >&2
    rm -f "$SNAPSHOT"
    if grep -Eq 'could not open relation with OID|cache lookup failed' "$log" && (( attempt < 3 )); then
      say "Snapshot colidiu com DDL; retry $attempt/3 em 3s..."
      sleep 3
      continue
    fi
    fail "pg_dump falhou"
  done
  test -s "$SNAPSHOT" || fail "snapshot vazio"
  pg_restore -l "$SNAPSHOT" >/dev/null || fail "snapshot inválido"
  sha256sum "$SNAPSHOT" >"$SNAPSHOT.sha256"
  docker service inspect "$SERVICE" >"$SPEC"
  ok "snapshot válido: $SNAPSHOT"
}

gate_clone() {
  CLONE="gate_${DB}_$(date +%Y%m%d%H%M%S)"
  say "== CLONE GATE: $CLONE =="
  docker exec -e PGPASSWORD="$DBPASS" "$CID" psql -h "$DBHOST" -p "$DBPORT" -U "$DBUSER" -d postgres -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE \"$CLONE\" OWNER \"$DBUSER\""
  trap 'docker exec -e PGPASSWORD="$DBPASS" "$CID" psql -h "$DBHOST" -p "$DBPORT" -U "$DBUSER" -d postgres -q -c "DROP DATABASE IF EXISTS \"$CLONE\" WITH (FORCE)" >/dev/null 2>&1 || true' EXIT
  docker run --rm -i postgres:16-alpine pg_restore --no-owner --no-acl --clean --if-exists     -h "$DBHOST" -p "$DBPORT" -U "$DBUSER" -d "$CLONE" <"$SNAPSHOT" >/dev/null 2>&1 ||     PGPASSWORD="$DBPASS" pg_restore --no-owner --no-acl -h "$DBHOST" -p "$DBPORT" -U "$DBUSER" -d "$CLONE" "$SNAPSHOT" >/dev/null

  GATE_LOG="$(mktemp)"
  args=(--rm --entrypoint odoo "$IMAGE" -d "$CLONE")
  [[ -n "$UPGRADE_MODULES" ]] && args+=(-u "$UPGRADE_MODULES")
  [[ -n "$INSTALL_MODULES" ]] && args+=(-i "$INSTALL_MODULES")
  args+=(--db_host "$DBHOST" --db_port "$DBPORT" --db_user "$DBUSER" --db_password "$DBPASS" --addons-path "$ADDONS_PATH" --stop-after-init --no-http --log-level=warn)
  docker run "${args[@]}" >"$GATE_LOG" 2>&1 || { tail -120 "$GATE_LOG" >&2; fail "gate Odoo falhou"; }
  grep -Eq 'CRITICAL|Traceback|Failed to initialize|incompatible version|not installable|ParseError' "$GATE_LOG" && { tail -120 "$GATE_LOG" >&2; fail "gate Odoo encontrou erro crítico"; }

  EXPECTED_SQL="$(printf "'%s'," ${EXPECTED_MODULES//,/ })"; EXPECTED_SQL="${EXPECTED_SQL%,}"
  total_expected="$(awk -F',' '{print NF}' <<<"$EXPECTED_MODULES")"
  installed="$(docker exec -e PGPASSWORD="$DBPASS" "$CID" psql -h "$DBHOST" -p "$DBPORT" -U "$DBUSER" -d "$CLONE" -t -A -c "select count(*) from ir_module_module where name in ($EXPECTED_SQL) and state='installed'")"
  [[ "$installed" == "$total_expected" ]] || fail "gate: $installed/$total_expected módulos installed"
  ok "gate: $installed/$total_expected módulos installed"
}

rollout_and_upgrade() {
  say "== ROLLOUT =="
  docker service update --image "$IMAGE" --update-order start-first --update-parallelism 1 --update-failure-action rollback --update-monitor "$UPDATE_MONITOR" --detach=false "$SERVICE" >/dev/null
  db_ctx

  say "== PROD UPGRADE =="
  PROD_LOG="$(mktemp)"
  args=(--rm --entrypoint odoo "$IMAGE" -d "$DB")
  [[ -n "$UPGRADE_MODULES" ]] && args+=(-u "$UPGRADE_MODULES")
  [[ -n "$INSTALL_MODULES" ]] && args+=(-i "$INSTALL_MODULES")
  args+=(--db_host "$DBHOST" --db_port "$DBPORT" --db_user "$DBUSER" --db_password "$DBPASS" --addons-path "$ADDONS_PATH" --stop-after-init --no-http --log-level=warn)
  docker run "${args[@]}" >"$PROD_LOG" 2>&1 || { tail -160 "$PROD_LOG" >&2; fail "upgrade real falhou; snapshot=$SNAPSHOT"; }
  grep -Eq 'CRITICAL|Traceback|Failed to initialize|incompatible version|not installable|ParseError' "$PROD_LOG" && { tail -160 "$PROD_LOG" >&2; fail "upgrade real com erro crítico; snapshot=$SNAPSHOT"; }

  say "== REGISTRY REFRESH =="
  docker service update --force --update-order start-first --update-failure-action rollback --update-monitor "$UPDATE_MONITOR" --detach=false "$SERVICE" >/dev/null
  check_current
  ok "DEPLOY_OK image=$IMAGE snapshot=$SNAPSHOT"
}

case "$CMD" in
  check)
    check_current
    ;;
  gate)
    check_current
    docker pull "$IMAGE" >/dev/null
    db_ctx
    snapshot
    gate_clone
    ok "GATE_OK image=$IMAGE snapshot=$SNAPSHOT"
    ;;
  deploy)
    check_current
    docker pull "$IMAGE" >/dev/null
    db_ctx
    snapshot
    gate_clone
    rollout_and_upgrade
    ;;
esac
