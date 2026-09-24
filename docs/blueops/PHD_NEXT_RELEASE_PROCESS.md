# PHD — processo de replicação das próximas atualizações/releases

Data-base: 24/09/2026  
Objetivo: permitir que o Natan replique amanhã as novas atualizações do PHD sem repetir o drift de código/manifest ocorrido hoje.

## Estado de partida validado

- Código canônico: `conexaoazul/BlueApps19`
- Branch canônica: `19.0-mod`
- Commit atual contendo o `custom_contract.py` enviado/validado: `0d0db09263fb5d6ea6bfc2d6f8aa5ab9cd512b26`
- Service produção: `odoo-demo-phd-transporte`
- Banco: `phd_demo`
- Imagem ativa: `ghcr.io/conexaoazul/odoo-demo-phd:19-custom-contract-0d0db09`
- Digest da imagem: `sha256:00edaa1cad4a62a05d4f2cd4d0d856d466bcb4893919777a1684961d281eaf67`
- Backup pré-release atual: `/var/lib/blueops/backups/phd/phd_demo-blueops-20260924-204649.dump`
- `custom_contract.py` em produção: SHA-256 `78aa8af2387189ae10fc0bfdf9eb1c808bb18a3a368cebcc10a62621afac88c0`

## Regra principal

Não usar igualdade de versão no `__manifest__.py` como prova de que dois módulos possuem o mesmo código.

Toda release deve comparar:
1. commit anterior implantado;
2. HEAD novo;
3. arquivos realmente alterados;
4. conteúdo da imagem candidata;
5. conteúdo efetivamente ativo após deploy.

Não usar o botão **Atualizar** da tela Apps para release coordenada.

## Processo para amanhã

### 1. Sincronizar e identificar o delta

```bash
git clone --branch 19.0-mod https://github.com/conexaoazul/BlueApps19.git
cd BlueApps19
git fetch origin
git reset --hard origin/19.0-mod

git log --oneline 0d0db09263fb5d6ea6bfc2d6f8aa5ab9cd512b26..HEAD
git diff --stat 0d0db09263fb5d6ea6bfc2d6f8aa5ab9cd512b26..HEAD
```

Revisar cada arquivo alterado. Mudanças em segurança, regras, access CSV, wizard, renderização, snapshot, assinatura ou `custom_contract.py` devem ser tratadas como críticas.

### 2. Validar versão e escopo

Antes de build:

```bash
grep -R '"version"' blue_custom_contracts*/__manifest__.py
```

Confirmar:
- versão incrementada;
- nenhuma regressão de arquivos de hardening;
- nenhuma remoção acidental de regras/grupos/testes;
- apenas módulos realmente alterados entram no release.

Arquivos de hardening que devem continuar presentes no dynamic:

```text
security/security.xml
security/document_request_rules.xml
models/field_autosync.py
tests/test_document_request_hardening.py
```

### 3. Rodar validações estáticas

```bash
python3 scripts/qa_phd_whatsapp_dynamic_static.py
python3 scripts/validate_odoo_module.py blue_custom_contracts
python3 scripts/validate_odoo_module.py blue_custom_contracts_dynamic
python3 -m py_compile blue_custom_contracts_dynamic/models/custom_contract.py
```

Resultado esperado:
- `PHD_WHATSAPP_GATE=PASS`;
- zero erros nos módulos;
- `py_compile` sem erro.

### 4. Construir imagem candidata imutável

Para alteração pequena e localizada, preferir derivar da última imagem de produção validada e copiar apenas os módulos/arquivos alterados.

Tag recomendada:

```text
ghcr.io/conexaoazul/odoo-demo-phd:19-<release>-<sha7>
```

Exemplo:

```text
ghcr.io/conexaoazul/odoo-demo-phd:19-phd-<sha7>
```

Depois validar que o arquivo/módulo dentro da imagem possui o mesmo hash do Git.

### 5. Gate obrigatório sem produção

```bash
phd-healthcheck

PHD_LOG_SINCE=5m phd-deploy \
  --image ghcr.io/conexaoazul/odoo-demo-phd:<tag>
```

Só avançar se terminar com:

```text
OK: gate: 7/7 módulos installed
OK: GATE_OK
```

Esse gate deve confirmar:
- Swarm 1/1;
- container healthy;
- PostgreSQL 3/3 fora de recovery;
- nenhum módulo em estado transitório;
- HTTP 200/TLS;
- snapshot válido;
- clone restaurado;
- upgrade do clone;
- 7/7 módulos `installed`.

### 6. Publicar a imagem

```bash
docker push ghcr.io/conexaoazul/odoo-demo-phd:<tag>
```

Registrar o digest retornado pelo GHCR.

### 7. Promover produção

Somente depois de `GATE_OK`:

```bash
PHD_LOG_SINCE=5m phd-deploy \
  --image ghcr.io/conexaoazul/odoo-demo-phd:<tag> \
  --apply
```

O BlueOps deve fazer:
1. novo snapshot;
2. novo clone-gate;
3. rollout `start-first`;
4. upgrade real dos módulos;
5. refresh do registry;
6. healthcheck final.

Resultado obrigatório:

```text
OK: DEPLOY_OK
```

### 8. Validação pós-deploy

Confirmar:

```bash
phd-healthcheck
```

E validar:
- imagem ativa do service;
- hash dos arquivos principais;
- versão no manifest;
- HTTP 200;
- TLS válido;
- nenhum módulo `to upgrade/to install/to remove`;
- ausência de erros críticos recentes.

Também testar manualmente no PHD:
- wizard;
- **Gerar link**;
- abertura do link;
- campos dinâmicos;
- assinatura;
- geração/renderização do documento;
- chatter;
- PDF/artefato final quando aplicável.

## Critério de bloqueio

Parar a release se qualquer um ocorrer:
- PostgreSQL em recovery;
- módulo em estado transitório;
- diferença de código não explicada;
- remoção de hardening;
- erro de view/xpath;
- falha no clone-gate;
- menos de 7/7 módulos installed;
- HTTP/TLS falhando;
- imagem sem digest;
- hash do arquivo na imagem diferente do Git esperado.

## Evidências a registrar a cada release

Registrar no e-mail/PR:
- commit/PR;
- tag da imagem;
- digest;
- snapshot;
- resultado do gate;
- resultado do deploy;
- versões dos módulos alterados;
- hashes dos arquivos críticos;
- resultado do teste funcional.

## Comandos resumidos

```bash
phd-healthcheck

# gate
PHD_LOG_SINCE=5m phd-deploy --image ghcr.io/conexaoazul/odoo-demo-phd:<tag>

# produção
PHD_LOG_SINCE=5m phd-deploy --image ghcr.io/conexaoazul/odoo-demo-phd:<tag> --apply
```

Fluxo obrigatório:
**Git diff → validação estática → imagem imutável → clone-gate → push → --apply → healthcheck → smoke funcional.**
