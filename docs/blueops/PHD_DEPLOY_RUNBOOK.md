# PHD — desenvolvimento, gate e deploy

Servidor operacional: `azul2`.

## Referências atuais

- Código canônico: `conexaoazul/BlueApps19`, branch `19.0-mod`
- Reconciliação PHD: PR `conexaoazul/BlueApps19#701`
- Merge PHD: `17864dc511d8a35156dca9f66f4fe640065e721d`
- Imagem validada: `ghcr.io/conexaoazul/odoo-demo-phd:19-bestof-4bf6965`
- Service: `odoo-demo-phd-transporte`
- Banco: `phd_demo`
- Tooling: `conexaoazul/act` → `scripts/odoo-blueops.sh`
- Preset: `config/odoo/phd.env`

## Operação diária

```bash
phd-healthcheck
```

Gate completo sem tocar produção:

```bash
phd-deploy --image ghcr.io/conexaoazul/odoo-demo-phd:<tag>
```

Promoção após gate:

```bash
phd-deploy --image ghcr.io/conexaoazul/odoo-demo-phd:<tag> --apply
```

Não usar o botão Atualizar da UI para releases coordenadas. Em 24/09/2026 um upgrade iniciado pela UI coincidiu com recovery do PostgreSQL e deixou módulos presos em `to upgrade`.

## O que o gate garante

- lock exclusivo do ambiente;
- service/container saudáveis;
- PostgreSQL estável em 3 amostras;
- nenhum módulo em estado transitório;
- HTTP 200 + TLS válido;
- snapshot único e validado;
- clone descartável do banco;
- upgrade/install no clone;
- todos os módulos esperados em `installed`.

## Fluxo para novas funcionalidades

1. Branch no `BlueApps19/19.0-mod`.
2. Implementar módulo/migração/integração.
3. Rodar validações e abrir PR.
4. Merge apenas com revisão/gates.
5. Gerar imagem imutável do PHD.
6. Rodar `phd-deploy --image <tag>`.
7. Se `GATE_OK`, rodar novamente com `--apply`.
8. Testar fluxo funcional no PHD e observar logs.

## Equipe

Usuários com acesso Docker no `azul2` podem usar o mesmo tool.
O acesso ao GHCR deve ser individual e com escopo mínimo `read:packages`.

## Backups

Backups novos do BlueOps ficam em:

`/var/lib/blueops/backups/phd`

O diretório é compartilhado pelo grupo `docker` e o restore continua sujeito a decisão humana.
