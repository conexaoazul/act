# PHD deploy runbook

Servidor de execucao: `azul2`.

## Referencias

- Codigo Odoo: `conexaoazul/BlueApps19:19.0-mod`
- PR de reconciliacao PHD: `conexaoazul/BlueApps19#701`
- Merge: `17864dc511d8a35156dca9f66f4fe640065e721d`
- Imagem validada: `ghcr.io/conexaoazul/odoo-demo-phd:19-bestof-4bf6965`
- Digest: `sha256:f97a97ac05756d61b79dc475ccf2788ed2ce75463e1cc55836c21ad53efa03b9`
- Service: `odoo-demo-phd-transporte`
- Banco: `phd_demo`

## Acesso

Use o usuario Linux `natan.nunes` no `azul2`, preferencialmente pela rede privada/Tailscale.
O usuario ja pertence ao grupo `docker`, suficiente para operar o Swarm sem sudo.

## Check rapido

```bash
docker service ls --filter name=odoo-demo-phd-transporte
docker service ps odoo-demo-phd-transporte --no-trunc | head
curl -fsSL -o /dev/null https://phd-demo.conexaoazul.com
docker service logs --since 30m --tail 500 odoo-demo-phd-transporte 2>&1 \
  | grep -Ei 'CRITICAL|Traceback|recovery mode|not installable|incompatible version'
```

## Rollout da imagem

```bash
IMAGE=ghcr.io/conexaoazul/odoo-demo-phd:<tag>
docker pull "$IMAGE"
docker service update --image "$IMAGE" \
  --update-order start-first \
  --update-parallelism 1 \
  --update-failure-action rollback \
  --update-monitor 20s \
  --detach=false odoo-demo-phd-transporte
```

## Gate obrigatorio

Antes do banco real, faca clone descartavel de `phd_demo` e rode os mesmos `-u/-i` da release.
So promova quando os 7 modulos terminarem em `installed`.

Upgrade:
`blue_custom_contracts,blue_custom_contracts_dynamic,blue_custom_hr_employee,blue_hr_employee_medical,blue_phd_documents`

Install:
`blue_whatsapp_custom_contracts,blue_whatsapp_custom_contracts_dynamic`

## Guardrails

- Sempre backup `pg_dump -Fc` antes do upgrade real.
- Nunca fazer restore automatico apos falha de upgrade; exigir decisao humana.
- Tratar PostgreSQL em `recovery mode` como bloqueio.
- O healthcheck deve verificar filestore: ha referencias historicas a anexos sem arquivo fisico.
- O repositorio `conexaoazul/act` e publico; nao instalar runner self-hosted de producao nele sem isolamento e ACL dedicados.
