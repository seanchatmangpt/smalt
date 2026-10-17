# ERRC next-window queue — prune/tighten (v26.10.16)

> **FOLDABLE 2026-10-16 (lane 4, CLOSURE wave)** — all actionable items
> folded into `NEXT_WINDOW.md` section 14 with close conditions; parks
> carried verbatim. No further work lands here; this file is an
> execution record.

Source: errc-cycle prune/tighten phase run 2026-10-16 against /Users/sac/smalt
under a docs/scripts-only freeze (no build/test runs this pass). Static
analysis only — every lib/test item below is a **verify-then-kill** work
order, not a confirmed kill; no GAP token minted, no KD row touched.

## Executed this pass (ELIMINATE / REDUCE, docs+scripts lanes only)

| action | files | evidence |
|---|---|---|
| KILL: scratch bench substrate logs (~9.8 MB) | `docs/tmp/bench-substrate-*.log` (10 files) | referenced by no live doc; historical receipts name only the directory's absence (x3-receipts-relocation.md:34, bench-05-python-mirror.md:71); `docs/tmp` now empty |
| TIGHTEN: stale "38 admitted types" tokens | `docs/WIRE_PARITY.md:94`, `docs/PACK_INTEGRATION/canonical-projection.md:17`, `docs/STRESS/GATE_COST.md:16` | re-counted on disk this pass: `@admitted_resource_types` in `lib/smalt/registry.ex` = 41 string entries; `docs/capabilities.json` capabilities array = 41. Both counts re-derived 2026-10-16, not recalled |
| NOT TOUCHED: `ash-kudzu-integration.md` "38" prose | (window record — records are not edited) | FINAL.md certification block already supersedes it on record |

## ELIMINATE queue (lib/ + test/) — next window, with real tooling

Static pass could not confirm any module dead (grep-suspect modules
`SHACLProjection`, `Mix.Tasks.Smalt.Dspy.Remediation` both resolved
test-referenced). Queue = mechanical census first, kills second.

1. **Unused-module census via compiler, not grep.** Run
   `MIX_BUILD_ROOT=_build-errc mix compile --warnings-as-errors` (or
   `mix xref graph` analysis) and kill every lib/ module with zero inbound
   references. Grep-only kills are banned — grep misses alias/dynamic
   dispatch. Verify-first candidates surfaced by this pass (lowest inbound
   ref counts; grep for module segment outside own file):
   - `lib/smalt/runtime_contracts/support.ex`
   - `kql.ex` / `resource_graph.ex` segments counted via loose segment grep — re-verify
   - `lib/smalt/hw/virtual_serial.ex` (4 segment refs, all narrow)
   - `lib/smalt/ocel/revops/powl_bridge.ex` (3 refs, revops-internal only)
2. **Batch-callback fence test** (`test/`): KD-53 (EH multi-event batch drops
   inner messages 2..N, filed commit fd9cfea) needs its court. Close condition:
   a real pyamqp batch test that flips on the mutant fix and pins inner-message
   delivery; then `kd_flip.py --apply KD-53` per the kd-registrar path.
3. **Re-probe `ts-event-hubs` receipt** named inside
   `docs/WIRE_PARITY.md` Event Hubs SDK smoke row: refresh
   `sdk-results/ts-event-hubs.md` from a live 4/4 probe to flip the
   REGISTERED-DIVERGENCE cell (named task inside WIRE_PARITY, still open).

## REDUCE queue (docs+scripts lanes, may run in the frozen lane class)

4. **`scripts/tf_provider_wrap.sh` kill-or-wire verification.** Only inbound
   reference is a comment in `scripts/tf_mirror_env.sh:93` ("via
   scripts/tf_provider_wrap.sh"). Verify whether `tf_mirror_env.sh`/`tf_smoke.sh`
   actually invoke it; if truly unwired, delete the script + the comment, with a
   receipt naming the invocation-absence proof (grep over justfile.d + scripts).
5. `docs/audit/` (SDK_SURFACE_PARITY_AUDIT.md, census_table.tsv,
   sections/aud1-4) — staleness re-check against the canonical
   `SDK_MATRIX.md` + KD register; archive if it duplicates the register
   (mirror the v26.10.14 archival pattern: move to `docs/archive/`, add pointer
   in archive/README.md).
6. `docs/PACK_INTEGRATION/REMAINING_CENSUS.md` (dated 2026-10-14, carries an
   open "Assumptions (flagged for lane owners)" block with an unverified I8
   trio assumption) — re-census or archive; an unverified-assumption doc in
   user-facing docs/ is drift risk.

## REDUCE (scripts) — parking decision

7. `docs/audit/census_table.tsv` and `scripts/__pycache__` exist on disk but
   `scripts/__pycache__` is untracked cache (verify .gitignore covers it; if
   not, add the ignore line — scripts-lane edit). Verify before acting.
8. `scripts/wave_telemetry.sh` is wired (13 refs) but `docs/jira/v26.10.16/wave-telemetry.jsonl`
   sits un-rolled-up in the window dir — decide roll-up vs deletion at wrap
   (coordinator decision, parked here, not acted on).

## Parked (never auto-resolve)

- P1: `GAP(blob-comp-lease-absent)` / blob delete-precedence divergence — feature-scale, owner-proposal pending; not an ERRC prune item, listed to prevent re-discovery.
- P2: SUSPECT-receipt archival mechanism (NEXT_WINDOW.md item 3) — requires indexer change (code lane), parked per freeze.
