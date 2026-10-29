# T-15 — IaC state export: bicep first, terraform stub second

- status: CODE-COMPLETE (2026-10-29): r9, awaiting integration run
- window: v26.10.28 · maps-to: Topaz v1.14 "IaC state export — `export --format bicep` · `--format terraform` (HCL + tfvars stub)" · verdict-at-open: **GAP** (foundation exists)
- size: **M** · depends-on: — · parity-leg: export round-trip (what-if/plan diff)

## current state (evidence)

No export CLI. The semantic projection already normalizes mounted
resources (`lib/smalt/semantic/resource.ex` + `lib/smalt/projection/`) —
the natural substrate for an exporter (map row). Export is read-only: no
actuation-gate conflict.

## scope

1. `export --format bicep` (substrate-side mix task / script): renders the
   provisioned resource graph as `.bicep` — resource blocks with real
   symbolic names, properties from the projection, `output` blocks for
   keys/endpoints where the real export tool does.
2. `export --format terraform`: `azurerm` HCL resources + a `terraform.tfvars`
   stub (names/locations), from the same projection walk.
3. Both emitted from ONE projection pass (single-source law — the formats
   are renderers, not separate exporters).

## non-goals

- Reverse import (that is T-02); drift detection; module extraction.

## Definition of Done — the Azure developer's view

You build your local world interactively — SDK calls, `az` commands, a
little terraform — and then want it as code. You run the export command
and get a `main.bicep` that opens in your editor looking like something
you would have written: correct resource types, your names as symbolic
names, locations and SKUs filled in. `bicep build` compiles it clean, and
— the moment of truth — deploying that file to a FRESH smalt instance
reproduces your world so exactly that your application probes pass
unchanged against it. The terraform flavor round-trips the same way:
`terraform init && terraform plan` against a fresh substrate shows no
changes after apply. The bicep and HCL never disagree, because both come
from the same projection.

## receipts required

Export→build receipt (bicep build clean); round-trip receipt (deploy to
fresh substrate → probe-parity with the original world); HCL plan-no-changes
receipt; single-source witness (one projection walk, two renderers).
