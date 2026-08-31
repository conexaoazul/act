# Conexao Azul BlueOps integration

This directory keeps Conexao Azul-specific integration additive and isolated from the upstream `nektos/act` codebase.

## Responsibility split

- `conexaoazul/act`: local GitHub Actions execution engine.
- `conexaoazul/BlueApps19`: Odoo/Blue Runtime contracts, profiles, locks, validators and workflows.
- The wrapper in this directory does not duplicate Odoo business rules.

## Build the fork

```bash
make build
```

The local binary is expected at:

```text
dist/local/act
```

## Run the Blue Runtime preflight

With the repositories checked out side by side:

```text
workspace/
├── act/
└── BlueApps19/
```

run:

```bash
cd act
./conexaoazul/blueops/run-blue-runtime.sh ../BlueApps19
```

The wrapper executes this workflow from the BlueApps19 checkout:

```text
.github/workflows/blue-runtime-local-preflight.yml
```

It resolves the exact BlueApps19 HEAD, runs the semantic validator and unit tests, produces the runtime resolution, Odoo Addon BOM (OABOM) and normalized QA input, and writes evidence only.

## Safety contract

This integration must remain evidence-only. A successful local preflight does **not** authorize merge, deploy, production changes, external messages, entitlement changes, or financial actions.

GitHub Actions `startup_failure` is also not converted into a local PASS. Local execution is independent evidence tied to the exact local SHA.

## Overrides

```bash
ACT_BIN=/path/to/act \
BLUEAPPS_DIR=/path/to/BlueApps19 \
BLUE_RUNTIME_WORKFLOW=.github/workflows/blue-runtime-local-preflight.yml \
./conexaoazul/blueops/run-blue-runtime.sh
```

Additional arguments after the BlueApps19 path are forwarded to `act`.
