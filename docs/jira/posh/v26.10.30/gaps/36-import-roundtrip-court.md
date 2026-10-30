# 36 Import Roundtrip Court: create → forget → import → zero-drift plan → destroy

Status: ALIVE — executable court landed and run on the live smalt ARM plane
(127.0.0.1:9443), 6 resource types roundtrip green this session (ALIVE floor
was 5); residue-0 verified after every run.

- Court: `adapters/terraform-provider-smalt/scripts/import_roundtrip_court.sh`
  (in `/Users/sac/smalt`)
- Plane: smalt-on-kind ARM face, bearer-gated (healthz 401 unauthenticated)
- Provider: dev-override `hashicorp/azurerm` →
  `/Users/sac/smalt/adapters/terraform-provider-smalt` (unpinned working
  tree, see 24-cross-repo-skew S8; the court rebuilds the provider from that
  tree every run via `scripts/build_install.sh` — which is also why the law
  row flipped within one session: another lane moved the LAW api-version
  between my two runs)

## Method (per type)

1. `terraform apply` — create the resource LIVE on the wire via the
   provider's own create path (the PUT-first requirement; import against
   smalt needs the resource to exist on the plane).
2. `terraform state rm <addr>` — forget the adopted state; resource stays
   live.
3. `terraform import <addr> <id>` — MUST exit 0 (typed refusal rows count as
   court findings, never silent skips).
4. id-equality: imported state id must equal the live id (waived for rows
   using the parity-form import-id override, where the provider's Read
   canonically rewrites the id — the plan gate covers drift).
5. `terraform plan -detailed-exitcode` MUST be 0 — zero drift.
6. `terraform destroy` MUST exit 0; EXIT trap scrubs any leftover `irtc-*`
   fixture RGs via the STS bearer, then re-lists.

Every stage writes an `RC_*` marker to a per-row log; the row is PASS only if
all six markers are 0. A missing marker is FAIL, never a silent pass.

## Receipt — full-court run 2026-10-30T20:07:38Z (work /tmp/import-roundtrip-court.vEVP1p)

| Row | Verdict | Receipt |
|---|---|---|
| rg | PASS | all six RC_*=0 |
| kv | PASS | all six RC_*=0 |
| kv-secret | PASS | RC_IMPORT=0 via parity-form ARM-path id; provider Read rewrites id to vault-URL form; RC_PLAN=0 (no drift) |
| cae | PASS | all six RC_*=0 |
| acr | PASS | all six RC_*=0 (S1 ACR api-version skew did NOT fire — create/read/delete green on current tree) |
| law | PASS then FAIL within the same session | standalone run 20:04 PASS; full run 20:07 FAIL at create: smalt plane refuses `2022-10-01` (top `2020-08-01`) — provider LAW api-version rose mid-session on the shared tree; S1-class skew, live witness |
| uai | FAIL (honest, court-observed) | import exits 0, first refresh refuses: `UNSUPPORTED(attr roundtrip): principal_id` — GAP22-2 is still open, now with a live-plane receipt |
| role_assignment | FAIL | create OK; post-import plan drifts: `role_definition_id` imported as the config NAME, not the definition id; `principal_type` computed lost → forced replacement |
| role_definition | FAIL | post-import plan drifts: `permissions` list block not seeded by import → update-in-place |
| container_app | FAIL | post-import plan drifts: `template` block not seeded by import → update-in-place |
| FIC | SKIP (loud) | blocked: nested FIC route 404 on smalt plane = KD-08; court row stays loud until KD-08 closes |
| consumer rows 11-12 (registry-nested RA ids) | SKIP (loud) | re-courted by the consumer-root court once it lands |

GREEN SET: rg, kv, kv-secret, cae, acr (5+) — meets the ALIVE floor.

## Court-surfaced defects (all live-plane, each closes when its row flips PASS)

- D1 `law`: provider api-version 2022-10-01 vs smalt top 2020-08-01 → every
  LAW create refusable (GAP24 S1-class). Witness
  `/tmp/import-roundtrip-court.vEVP1p/law.log`.
- D2 `uai` GAP22-2 confirmed on the wire: import seeds only id/rg/name;
  refresh refuses fabricated `principal_id`. Opt-in env
  `TFPOSH_ALLOW_FABRICATED_IDS=1` exists but the court keeps the default
  (honest refusal) so the row stays RED until import seeds the attrs.
- D3 `role_assignment`/`role_definition`/`container_app`: ImportState sets
  only id/rg/name; computed attrs and list blocks (permissions, template)
  are dropped from imported state → guaranteed post-import drift. This is
  the GAP22-2 class generalized: **import does not roundtrip anything beyond
  id/rg/name**. Close: read-before-import (seed attrs from the plane) or
  registered divergence rows + consumer-side guard.

## Falsifier

Executable, on the live plane:

```
smalt/adapters/terraform-provider-smalt/scripts/import_roundtrip_court.sh
```

- Exit 0 = every non-SKIP row green (currently exit 1: uai/ra/rd/ca drift
  rows + law create refusal are open findings D1-D3).
- Non-vacuity: the court PUTs each resource first (apply), then forgets the
  state and re-imports — an import that did nothing would not reproduce the
  id, and the zero-drift plan would fail; killing a row's create makes the
  row FAIL (witnessed this session on law). Residue-0 is checked by the EXIT
  trap's re-list; witnessed scrubbing leftover RGs after failed runs.
- Re-run receipts land in a fresh mktemp work dir; GREEN SET >= 5 types is
  the ALIVE floor for this gap.
