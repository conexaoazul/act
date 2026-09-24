# BlueOps Odoo — deploy padronizado

O `odoo-blueops` padroniza atualização de ambientes Odoo em Docker Swarm com gate de banco antes de produção.

## Modelo

Cada ambiente tem somente um preset declarativo em `config/odoo/<ambiente>.env`.
O core fica em `scripts/odoo-blueops.sh` e não contém segredo.

Comandos:

```bash
odoo-blueops --config /etc/blueops/odoo/phd.env check
odoo-blueops --config /etc/blueops/odoo/phd.env gate --image <imagem>
odoo-blueops --config /etc/blueops/odoo/phd.env deploy --image <imagem>
```

Para PHD existem aliases compatíveis:

```bash
phd-healthcheck
phd-deploy --image <imagem>          # somente gate, não toca produção
phd-deploy --image <imagem> --apply  # promove após gate
```

## O que o core faz

1. lock exclusivo por ambiente, evitando dois deploys simultâneos;
2. valida service Swarm e container;
3. exige 3 amostras PostgreSQL estáveis e fora de recovery;
4. bloqueia se houver módulos em `to upgrade/to install/to remove`;
5. valida HTTP/TLS e erros críticos recentes;
6. reutiliza imagem local ou baixa do registry;
7. gera um único snapshot `pg_dump -Fc` com retry em colisão DDL;
8. valida o archive e usa o mesmo snapshot para clone-gate e rollback humano;
9. restaura clone descartável com compatibilidade entre versões PostgreSQL;
10. executa `-u/-i` no clone e exige todos os módulos esperados em `installed`;
11. em deploy, faz rollout `start-first` + rollback automático do Swarm;
12. executa upgrade real, refresh do registry e check final.

## Como cadastrar outro ambiente

Copie `config/odoo/phd.env` e altere apenas:
- `SERVICE`;
- `DB`;
- `URL`;
- `IMAGE_PREFIX`;
- `ADDONS_PATH`;
- `UPGRADE_MODULES`;
- `INSTALL_MODULES`;
- `EXPECTED_MODULES`;
- `BACKUP_ROOT`.

Credenciais de banco não entram no Git: o tool lê `HOST/PORT/USER/PASSWORD_FILE` do container Odoo em execução.

## Fluxo de desenvolvimento recomendado

1. desenvolver em branch no repositório canônico do produto;
2. abrir PR e executar validações estáticas/CI;
3. mergear somente com gates verdes;
4. construir/taguear imagem imutável;
5. executar `gate` no servidor;
6. revisar evidências;
7. executar `deploy`;
8. validar funcionalidade e logs.

Evite atualizar módulos pela UI em produção. A UI não oferece o mesmo snapshot, clone-gate, lock e controle de recovery.

## Segurança

- O repositório `conexaoazul/act` é público: não versionar tokens, senhas ou configs privadas.
- Para imagens GHCR novas, cada operador deve usar credencial dedicada somente `read:packages`.
- Não copiar token administrativo de outro usuário.
- Restore de backup continua sendo decisão humana; o tool não faz restore automático após migração parcial.
