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
RUNTIME_SSH="${RUNTIME_SSH:-}"
PRECREATE_EXTENSIONS="${PRECREATE_EXTENSIONS:-}"
DB_ADMIN_SERVICE="${DB_ADMIN_SERVICE:-}"
DB_ADMIN_USER="${DB_ADMIN_USER:-}"
DEPLOY_ENABLED="${DEPLOY_ENABLED:-1}"

if [[ "$CMD" != "check" ]]; then
  [[ "$DEPLOY_ENABLED" == "1" ]] || { echo "Gate/deploy desabilitado para $BLUEOPS_ENV pelo catálogo." >&2; exit 12; }
  [[ -n "$IMAGE" ]] || { echo "Falta --image" >&2; exit 2; }
  [[ "$IMAGE" == "$IMAGE_PREFIX"* ]] || { echo "Imagem fora do prefixo permitido: $IMAGE_PREFIX" >&2; exit 2; }
fi

LOCK_ROOT="${LOCK_ROOT:-/var/lib/blueops/locks}"
mkdir -p "$LOCK_ROOT"
LOCK="$LOCK_ROOT/blueops-odoo-${BLUEOPS_ENV}.lock"
touch "$LOCK"
chmod 0664 "$LOCK" 2>/dev/null || true
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "Outro deploy/check exclusivo de ${BLUEOPS_ENV} já está em execução." >&2
  exit 9
fi

say(){ printf '%s\n' "$*"; }
ok(){ say "OK: $*"; }
fail(){ say "FAIL: $*" >&2; exit 1; }

service_runtime_node() {
  docker service ps "$SERVICE" --filter desired-state=running --format '{{.Node}}' | head -1
}

runtime_docker() {
  if [[ -n "$RUNTIME_SSH" ]]; then
    local cmd
    printf -v cmd '%q ' docker "$@"
    ssh -o BatchMode=yes "$RUNTIME_SSH" "$cmd"
  else
    docker "$@"
  fi
}

runtime_host() {
  if [[ -n "$RUNTIME_SSH" ]]; then
    ssh -o BatchMode=yes "$RUNTIME_SSH" hostname
  else
    hostname
  fi
}

assert_runtime_transport() {
  local runtime_node actual_host
  runtime_node="$(service_runtime_node)"
  [[ -n "$runtime_node" ]] || fail "não foi possível determinar o nó runtime do service"
  if [[ -n "${RUNTIME_NODE:-}" && "$runtime_node" != "$RUNTIME_NODE" ]]; then
    fail "service $SERVICE roda em $runtime_node, mas catálogo espera $RUNTIME_NODE"
  fi
  actual_host="$(runtime_host 2>/dev/null || true)"
  [[ "$actual_host" == "$runtime_node" ]] || fail "transporte runtime inválido: esperado=$runtime_node obtido=${actual_host:-indisponível}"
  ok "runtime $runtime_node via ${RUNTIME_SSH:-local}"
}

cid() {
  assert_runtime_transport >/dev/null
  runtime_docker ps --filter "label=com.docker.swarm.service.name=$SERVICE" -q | head -1
}

db_ctx() {
  CID="$(cid)"
  [[ -n "$CID" ]] || fail "container runtime do service não encontrado"
  DBHOST="$(runtime_docker exec "$CID" sh -lc 'printf %s "$HOST"')"
  DBPORT="$(runtime_docker exec "$CID" sh -lc 'printf %s "${PORT:-5432}"')"
  DBUSER="$(runtime_docker exec "$CID" sh -lc 'printf %s "$USER"')"
  DBPASS="$(runtime_docker exec "$CID" sh -lc 'cat "$PASSWORD_FILE"')"
}

make_odoo_conf() {
  ODOO_CONF="$(mktemp)"
  chmod 600 "$ODOO_CONF"
  cat >"$ODOO_CONF" <<EOF
[options]
db_host = $DBHOST
db_port = $DBPORT
db_user = $DBUSER
db_password = $DBPASS
addons_path = $ADDONS_PATH
EOF
}

run_odoo_ephemeral() {
  local db="$1" log="$2"
  shift 2
  make_odoo_conf
  local mount_src="$ODOO_CONF"
  if [[ -n "$RUNTIME_SSH" ]]; then
    REMOTE_ODOO_CONF="/tmp/blueops-odoo-${BLUEOPS_ENV}-$$.conf"
    ssh -o BatchMode=yes "$RUNTIME_SSH" "umask 077; cat > '$REMOTE_ODOO_CONF'" <"$ODOO_CONF"
    mount_src="$REMOTE_ODOO_CONF"
  fi
  runtime_docker run --rm --user 0:0 \
    --mount "type=bind,src=$mount_src,dst=/run/blueops-odoo.conf,readonly" \
    --entrypoint odoo "$IMAGE" \
    -c /run/blueops-odoo.conf -d "$db" "$@" \
    --stop-after-init --no-http --log-level=warn >"$log" 2>&1
  local rc=$?
  if [[ -n "${REMOTE_ODOO_CONF:-}" ]]; then
    ssh -o BatchMode=yes "$RUNTIME_SSH" "rm -f '$REMOTE_ODOO_CONF'" || true
    REMOTE_ODOO_CONF=""
  fi
  rm -f "$ODOO_CONF"
  ODOO_CONF=""
  return "$rc"
}

ensure_image() {
  if runtime_docker image inspect "$IMAGE" >/dev/null 2>&1; then
    ok "imagem já disponível localmente"
    return 0
  fi
  if runtime_docker pull "$IMAGE" >/dev/null 2>&1; then
    ok "imagem baixada do registry"
    return 0
  fi
  fail "imagem não disponível localmente e pull falhou; autenticação GHCR read:packages necessária"
}

check_current() {
  local replicas health http code tls elapsed transient recovery recent
  replicas="$(docker service ls --filter "name=$SERVICE" --format '{{.Replicas}}' | head -1)"
  [[ "$replicas" == "1/1" ]] || fail "Swarm replicas=$replicas"
  ok "Swarm $SERVICE $replicas"

  db_ctx
  health="$(runtime_docker inspect "$CID" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')"
  [[ "$health" == "healthy" || "$health" == "running" ]] || fail "container=$health"
  ok "container $health"

  local stable=0 sample
  for sample in 1 2 3; do
    recovery="$(runtime_docker exec -i "$CID" python3 - "$DB" <<'PY'
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

  transient="$(runtime_docker exec -i "$CID" python3 - "$DB" <<'PY'
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
    if runtime_docker exec "$CID" sh -lc 'PW=$(cat "$PASSWORD_FILE"); export PGPASSWORD="$PW"; exec pg_dump -h "$HOST" -p "${PORT:-5432}" -U "$USER" -d '"$DB"' -Fc --no-owner --no-acl' >"$SNAPSHOT" 2>"$log"; then
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
  runtime_docker exec -i "$CID" pg_restore -l <"$SNAPSHOT" >/dev/null || fail "snapshot inválido"
  sha256sum "$SNAPSHOT" >"$SNAPSHOT.sha256"
  docker service inspect "$SERVICE" >"$SPEC"
  ok "snapshot válido: $SNAPSHOT"
}

cleanup_clone() {
  [[ -n "${CLONE:-}" && -n "${CID:-}" ]] || return 0
  runtime_docker exec -i -e BLUEOPS_CLONE="$CLONE" "$CID" python3 - <<'PY' >/dev/null 2>&1 || true
import os,pathlib,psycopg2
from psycopg2 import sql
pw=pathlib.Path(os.environ["PASSWORD_FILE"]).read_text().strip()
c=psycopg2.connect(host=os.environ["HOST"],port=os.environ.get("PORT","5432"),user=os.environ["USER"],password=pw,dbname="postgres")
c.autocommit=True
q=c.cursor()
q.execute(sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(os.environ["BLUEOPS_CLONE"])))
c.close()
PY
}

prepare_clone_extensions() {
  [[ -n "$PRECREATE_EXTENSIONS" ]] || return 0
  [[ -n "$DB_ADMIN_SERVICE" && -n "$DB_ADMIN_USER" ]] || fail "PRECREATE_EXTENSIONS exige DB_ADMIN_SERVICE e DB_ADMIN_USER"
  local admin_cid ext
  admin_cid="$(docker ps --filter "label=com.docker.swarm.service.name=$DB_ADMIN_SERVICE" -q | head -1)"
  [[ -n "$admin_cid" ]] || fail "container admin PostgreSQL não encontrado: $DB_ADMIN_SERVICE"
  IFS=',' read -ra exts <<<"$PRECREATE_EXTENSIONS"
  for ext in "${exts[@]}"; do
    [[ "$ext" =~ ^[A-Za-z0-9_]+$ ]] || fail "nome de extensão inválido: $ext"
    docker exec "$admin_cid" psql -U "$DB_ADMIN_USER" -d "$CLONE" -v ON_ERROR_STOP=1 -q -c "CREATE EXTENSION IF NOT EXISTS \"$ext\""
    ok "extensão preparada no clone: $ext"
  done
}

gate_clone() {
  CLONE="gate_${DB}_$(date +%Y%m%d%H%M%S)"
  say "== CLONE GATE: $CLONE =="
  runtime_docker exec -i -e BLUEOPS_CLONE="$CLONE" "$CID" python3 - <<'PY'
import os,pathlib,psycopg2
from psycopg2 import sql
pw=pathlib.Path(os.environ["PASSWORD_FILE"]).read_text().strip()
c=psycopg2.connect(host=os.environ["HOST"],port=os.environ.get("PORT","5432"),user=os.environ["USER"],password=pw,dbname="postgres")
c.autocommit=True
q=c.cursor()
q.execute(sql.SQL("CREATE DATABASE {} OWNER {}").format(sql.Identifier(os.environ["BLUEOPS_CLONE"]),sql.Identifier(os.environ["USER"])))
c.close()
PY
  trap cleanup_clone EXIT
  prepare_clone_extensions
  RESTORE_SQL="$(mktemp)"
  FILTERED_SQL="$(mktemp)"
  runtime_docker exec -i "$CID" pg_restore --no-owner --no-acl -f - <"$SNAPSHOT" >"$RESTORE_SQL"
  sed '/transaction_timeout/d;/^CREATE EXTENSION /d;/^COMMENT ON EXTENSION /d' "$RESTORE_SQL" >"$FILTERED_SQL"
  runtime_docker exec -i -e BLUEOPS_CLONE="$CLONE" "$CID" sh -lc 'PW=$(cat "$PASSWORD_FILE"); export PGPASSWORD="$PW"; exec psql -h "$HOST" -p "${PORT:-5432}" -U "$USER" -d "$BLUEOPS_CLONE" -v ON_ERROR_STOP=1 -q' <"$FILTERED_SQL"
  rm -f "$RESTORE_SQL" "$FILTERED_SQL"

  GATE_LOG="$(mktemp)"
  args=()
  [[ -n "$UPGRADE_MODULES" ]] && args+=(-u "$UPGRADE_MODULES")
  [[ -n "$INSTALL_MODULES" ]] && args+=(-i "$INSTALL_MODULES")
  run_odoo_ephemeral "$CLONE" "$GATE_LOG" "${args[@]}" || { tail -120 "$GATE_LOG" >&2; fail "gate Odoo falhou"; }
  grep -Eq 'CRITICAL|Traceback|Failed to initialize|incompatible version|not installable|ParseError' "$GATE_LOG" && { tail -120 "$GATE_LOG" >&2; fail "gate Odoo encontrou erro crítico"; }

  total_expected="$(awk -F',' '{print NF}' <<<"$EXPECTED_MODULES")"
  installed="$(runtime_docker exec -i -e BLUEOPS_CLONE="$CLONE" -e BLUEOPS_EXPECTED="$EXPECTED_MODULES" "$CID" python3 - <<'PY'
import os,pathlib,psycopg2
pw=pathlib.Path(os.environ["PASSWORD_FILE"]).read_text().strip()
names=[x for x in os.environ["BLUEOPS_EXPECTED"].split(",") if x]
c=psycopg2.connect(host=os.environ["HOST"],port=os.environ.get("PORT","5432"),user=os.environ["USER"],password=pw,dbname=os.environ["BLUEOPS_CLONE"])
q=c.cursor()
q.execute("select count(*) from ir_module_module where name = any(%s) and state='installed'",(names,))
print(q.fetchone()[0]); c.close()
PY
)"
  [[ "$installed" == "$total_expected" ]] || fail "gate: $installed/$total_expected módulos installed"
  ok "gate: $installed/$total_expected módulos installed"
}

rollout_and_upgrade() {
  say "== ROLLOUT =="
  docker service update --image "$IMAGE" --update-order start-first --update-parallelism 1 --update-failure-action rollback --update-monitor "$UPDATE_MONITOR" --detach=false "$SERVICE" >/dev/null
  db_ctx

  say "== PROD UPGRADE =="
  PROD_LOG="$(mktemp)"
  args=()
  [[ -n "$UPGRADE_MODULES" ]] && args+=(-u "$UPGRADE_MODULES")
  [[ -n "$INSTALL_MODULES" ]] && args+=(-i "$INSTALL_MODULES")
  run_odoo_ephemeral "$DB" "$PROD_LOG" "${args[@]}" || { tail -160 "$PROD_LOG" >&2; fail "upgrade real falhou; snapshot=$SNAPSHOT"; }
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
    ensure_image
    db_ctx
    snapshot
    gate_clone
    ok "GATE_OK image=$IMAGE snapshot=$SNAPSHOT"
    ;;
  deploy)
    check_current
    ensure_image
    db_ctx
    snapshot
    gate_clone
    rollout_and_upgrade
    ;;
esac
