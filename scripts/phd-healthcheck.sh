#!/usr/bin/env bash
set -euo pipefail

SERVICE="${PHD_SERVICE:-odoo-demo-phd-transporte}"
URL="${PHD_URL:-https://phd-demo.conexaoazul.com}"
DB="${PHD_DB:-phd_demo}"
SINCE="${PHD_LOG_SINCE:-30m}"
FAIL_ON_FILESTORE="${PHD_FAIL_ON_FILESTORE:-0}"

fail=0
warn=0

say() { printf '%s\n' "$*"; }
bad() { say "FAIL: $*"; fail=1; }
warning() { say "WARN: $*"; warn=1; }
ok() { say "OK: $*"; }

command -v docker >/dev/null || { bad "docker não encontrado"; exit 2; }
command -v curl >/dev/null || { bad "curl não encontrado"; exit 2; }

replicas=$(docker service ls --filter "name=$SERVICE" --format '{{.Replicas}}' | head -1)
image=$(docker service inspect "$SERVICE" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null || true)
[[ "$replicas" == "1/1" ]] && ok "Swarm $SERVICE $replicas" || bad "Swarm $SERVICE replicas=$replicas"
say "IMAGE: ${image:-unknown}"

cid=$(docker ps --filter "label=com.docker.swarm.service.name=$SERVICE" -q | head -1)
if [[ -z "$cid" ]]; then
  bad "container local do PHD não encontrado"
else
  health=$(docker inspect "$cid" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')
  [[ "$health" == "healthy" || "$health" == "running" ]] && ok "container $health" || bad "container $health"

  if docker exec "$cid" python3 - "$DB" <<'PY'
import os, pathlib, psycopg2, sys
db=sys.argv[1]
pw=pathlib.Path(os.environ["PASSWORD_FILE"]).read_text().strip()
conn=psycopg2.connect(host=os.environ["HOST"],port=os.environ.get("PORT","5432"),user=os.environ["USER"],password=pw,dbname=db,connect_timeout=5)
cur=conn.cursor()
cur.execute("select pg_is_in_recovery(), current_database()")
recovery,current=cur.fetchone()
print(f"DB_OK database={current} recovery={recovery}")
conn.close()
if recovery:
    raise SystemExit(4)
PY
  then ok "PostgreSQL aceita conexão e não está em recovery"; else bad "PostgreSQL indisponível ou em recovery"; fi

  set +e
  audit=$(docker exec "$cid" python3 - "$DB" <<'PY'
import os, pathlib, psycopg2, sys
db=sys.argv[1]
pw=pathlib.Path(os.environ["PASSWORD_FILE"]).read_text().strip()
conn=psycopg2.connect(host=os.environ["HOST"],port=os.environ.get("PORT","5432"),user=os.environ["USER"],password=pw,dbname=db,connect_timeout=5)
cur=conn.cursor()
cur.execute("select id,store_fname from ir_attachment where store_fname is not null")
rows=cur.fetchall()
root=pathlib.Path("/var/lib/odoo/filestore")/db
missing=[(i,s) for i,s in rows if not (root/s).exists()]
print(f"FILESTORE total={len(rows)} missing={len(missing)}")
for i,s in missing[:10]:
    print(f"MISSING {i} {s}")
conn.close()
raise SystemExit(3 if missing else 0)
PY
)
  audit_rc=$?
  set -e
  say "$audit"
  if (( audit_rc == 3 )); then
    if [[ "$FAIL_ON_FILESTORE" == "1" ]]; then bad "há anexos sem arquivo físico"; else warning "há anexos históricos sem arquivo físico"; fi
  elif (( audit_rc != 0 )); then
    warning "não foi possível auditar filestore"
  else
    ok "filestore consistente"
  fi
fi

http=$(curl -sS -L -o /dev/null --max-time 15 -w '%{http_code}|%{ssl_verify_result}|%{time_total}' "$URL" || true)
IFS='|' read -r code tls elapsed <<<"$http"
[[ "$code" == "200" ]] && ok "HTTP 200 em $URL (${elapsed}s)" || bad "HTTP $code em $URL"
[[ "$tls" == "0" ]] && ok "TLS válido" || bad "TLS verify=$tls"

crit=$(docker service logs --since "$SINCE" --tail 1200 "$SERVICE" 2>&1 | grep -E 'CRITICAL|Failed to initialize database|incompatible version|not installable|database system is in recovery mode' | tail -20 || true)
if [[ -n "$crit" ]]; then
  say "$crit"
  bad "erros críticos encontrados nos logs ($SINCE)"
else
  ok "sem CRITICAL/recovery/module-loader nos logs ($SINCE)"
fi

if (( fail )); then
  say "STATUS=FAIL"
  exit 1
fi
if (( warn )); then
  say "STATUS=WARN"
else
  say "STATUS=OK"
fi
