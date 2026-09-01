# Conexao Azul BlueOps integration

This directory keeps Conexao Azul-specific integration additive and isolated from the upstream `nektos/act` codebase.

## Responsibility split

- `conexaoazul/act`: local GitHub Actions execution engine.
- `conexaoazul/BlueApps19`: Odoo/Blue Runtime and Blue MCP contracts, validators and workflows.
- wrappers in this directory do not duplicate Odoo business rules or permissions.

## Build the fork

```bash
make build
```

The local binary is expected at `dist/local/act`.

## Recommended workspace

```text
workspace/
├── act/
└── BlueApps19/
```

## Blue Runtime preflight

```bash
cd act
bash ./conexaoazul/blueops/run-blue-runtime.sh ../BlueApps19
```

Executes `.github/workflows/blue-runtime-local-preflight.yml` from the exact BlueApps19 checkout and produces runtime resolution/OABOM evidence when that workflow exists in the selected branch.

## Blue MCP Platform preflight

```bash
cd act
bash ./conexaoazul/blueops/run-blue-mcp-platform.sh ../BlueApps19
```

Executes `.github/workflows/blue-mcp-platform-local-preflight.yml` from the exact BlueApps19 checkout. The MCP preflight validates the fail-closed policy contract, compiles the changed Python surface and parses manifests/XML. It does not perform Odoo writes or call MCP endpoints.

The current Blue MCP R2 lane covers:

- `blue_mcp_server` core governance hardening;
- optional `blue_mcp_automation` bridge for Scheduled Actions, Server Actions and Automated Actions;
- optional `blue_mcp_bitconn_webhook` bridge;
- privileged automation switch/group policy;
- removal of the obsolete `base.user_admin` XML reference;
- sales/App Store positioning and menu organization.

## Safety contract

These integrations are evidence-only. A successful local preflight does **not** authorize merge, deploy, production changes, external messages, entitlement changes, financial actions or privileged MCP mutations.

GitHub Actions `startup_failure` is never converted into a local hosted-CI PASS. Local `act` execution is independent evidence tied to the exact local SHA.

## Overrides

Runtime:

```bash
ACT_BIN=/path/to/act \
BLUEAPPS_DIR=/path/to/BlueApps19 \
BLUE_RUNTIME_WORKFLOW=.github/workflows/blue-runtime-local-preflight.yml \
bash ./conexaoazul/blueops/run-blue-runtime.sh
```

MCP:

```bash
ACT_BIN=/path/to/act \
BLUEAPPS_DIR=/path/to/BlueApps19 \
BLUE_MCP_WORKFLOW=.github/workflows/blue-mcp-platform-local-preflight.yml \
bash ./conexaoazul/blueops/run-blue-mcp-platform.sh
```

Additional arguments after the BlueApps19 path are forwarded to `act`.
