# Receipt: BK-GEN — replay-fence full pass over the generated-artifacts table

- **Date**: 2026-10-22
- **Lane**: BK-GEN (`MIX_BUILD_ROOT=_build-bkgen`)
- **Subject**: `/Users/sac/smalt` @ `0399abd6` (base); no generator-affecting files touched by this lane (lib/ untouched)
- **Standing**: **PARTIAL_ALIVE** — 9/10 artifact cells CLEAN byte-identical; 1 cell (ERROR_CODES.md) BLOCKED-with-owner
- **Context**: solo

## Command surface (all run in /Users/sac/smalt, PATH asdf shims first)

```bash
MIX_BUILD_ROOT=_build-bkgen mix smalt.gen
mix run -e 'Smalt.Projection.Canonical.write()'
mix ggen_igniter.sync --ontology lib/smalt/mcp/gen/smalt_mcp_surface.ttl \
  --query caps=/Users/sac/ggen-marketplace/packs/elixir-mcp-a2a-pack/queries/mcp_capabilities.rq \
  --template lib/smalt/mcp/gen/mcp_descriptor.ex.eex \
  --out lib/smalt/mcp/generated/mcp_descriptor.ex
python3 scripts/gen_error_codes.py [--check]
```

## Per-artifact table

| Artifact | Generator | Result | Evidence |
|---|---|---|---|
| lib/smalt/registry.ex | `mix smalt.gen` (ggen_igniter.sync, 9 queries / 204 rows) | **CLEAN byte-identical** | "unchanged (skipped, identical content)" |
| lib/smalt/ocel/event_registry.ex | `mix smalt.gen` | **CLEAN byte-identical** | "unchanged (skipped, identical content)", 9 queries / 129 rows |
| lib/smalt/store_tables.ex | `mix smalt.gen` | **CLEAN byte-identical** | "unchanged (skipped, identical content)", 8 queries / 161 rows |
| lib/smalt/cascade_edges.ex | `mix smalt.gen` | **CLEAN byte-identical** | "unchanged (identical)", 8 queries / 129 rows |
| lib/smalt/config.ex | `mix smalt.gen` | **CLEAN byte-identical** | "unchanged (identical)", 8 queries / 163 rows |
| lib/smalt/telemetry/semconv/registry.ex | `mix smalt.gen` (smalt-semconv-pack, 6 queries / 42 rows) | **CLEAN byte-identical** | "unchanged (identical)" |
| docs/capabilities.json | `mix run -e 'Smalt.Projection.Canonical.write()'` | **CLEAN byte-identical** | no diff after write |
| docs/THIRD_PARTY.md | Canonical.write rider | **CLEAN byte-identical** | no diff after write |
| lib/smalt/mcp/generated/mcp_descriptor.ex | `ggen_igniter.sync` (mcp pack, 1 query / 37 rows) | **CLEAN byte-identical** | "unchanged (identical)" |
| docs/ERROR_CODES.md | `python3 scripts/gen_error_codes.py` | **BLOCKED-with-owner** | see below |

## ERROR_CODES.md drift trace (BLOCKED)

1. First regen (early pass, tree near-clean) produced real drift: arm-gateway
   line-number shifts throughout `lib/smalt/arm_gateway/router.ex` plus 3 new
   codes (`RequestBodyTooLarge` 413, `InvalidRequestBody`, `LocationRequired`)
   — drift traces to landed lib changes → regenerate was lawful.
2. Re-run of `--check` minutes later: **stale again** — the same cell regenerates
   differently because `lib/smalt/egress_router.ex` (+48/-6) and
   `lib/smalt/attestation/maa.ex` (+8/-1) are **in-flight dirty under other
   lanes** (arm-gateway lines also moved again, indicating a concurrent
   coordinator transition on router.ex). The cell is a moving floor while those
   lanes are in flight.
3. Action: restored `docs/ERROR_CODES.md` to HEAD (`git checkout --`, byte-exact
   vs `git show HEAD:` verified). **Not committed.** Owner = whichever lanes hold
   `lib/smalt/arm_gateway/router.ex` / `lib/smalt/egress_router.ex` /
   `lib/smalt/attestation/maa.ex`; the regen+commit belongs in their integration
   step (or a post-landing sweep). Until then `python3 scripts/gen_error_codes.py --check`
   exits 1 on the dirty tree (witnessed) — the fence is non-vacuous.

## Replay-identity tests (task item 3)

Search of `test/` (literal greps: `smalt.gen`, `byte-identical`, `replay-identity`,
generated-file paths) found **no standalone per-artifact replay-identity test
files**: the ERROR_CODES byte fence is RETIRED@64f6099 (per
`scripts/gen_error_codes.py` docstring; caught by `--check` in
publish-dry/regen-identity instead), and the W1/W2 replay-identity tests named in
`docs/jira/v26.10.16/PROJECTION-ARCH-PLAN.md` are not present under `test/`.
The live fence mechanism is the generator's own identical-content check
(witnessed above for all 9 cells) + `gen_error_codes.py --check`. All exercised
fences are green except the BLOCKED ERROR_CODES cell; the one observed
`--check` exit 1 was the in-flight drift, not a fence defect.

## Falsifier / residual

- A post-landing rerun of this table once the router/egress/maa lanes land must
  show ERROR_CODES.md regen as CLEAN-or-committed; until then the cell is
  BLOCKED, owner named above.
- Residual tree state at receipt time: the two pre-existing dirty files
  (`docs/jira/v26.10.14/receipts/06-blob-x-ms-date-unvalidated.md`,
  `test/internal/ath1_batch_frame_receiver_court_test.exs`) belong to other
  lanes; this lane touched only the receipt file.
