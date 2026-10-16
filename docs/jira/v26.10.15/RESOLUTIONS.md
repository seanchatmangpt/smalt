# v26.10.15 — Shared Seams & Resolutions

Carry forward of `docs/jira/v26.10.14/RESOLUTIONS.md` (S1-S9), updated for the v26.10.15
lane partition (`_LANES.md`). S1/S3/S5/S6/S7/S8 carry forward with updated lane numbers;
S2/S4/S9 are v26.10.14-specific and retire unless re-witnessed. New seams T1-T5 record
this window's shared surfaces.

## S1 — `SmaltTest.Lifecycle.ensure_store_up/0` (v26.10.14 lanes 01→02,10; retired in v26.10.15 unless re-witnessed)

The v26.10.14 seam is landed. It carries forward as **infrastructure, not a seam**: lane 02
(Store.namespace) builds on it; no v26.10.15 lane owns a divergent variant. If a lane finds
itself hand-rolling restart+wait, that is a defect — use the landed helper.

## S3 — `lib/smalt/egress_router.ex` (carried forward: lanes 04 / 17)

The v26.10.14 split is landed. v26.10.15 law: **no lane edits `egress_router.ex` except
lane 04's auth-mode listener work, and then only additively per the seed-01 §4 decision**
(mode is a listener property; per-request mode headers stay rejected). Any other lane that
must touch it escalates to the coordinator. Shared regression set unchanged:
`test/wire/egress_wire_test.exs`, `test/data_plane/{cosmos,key_vault_actions,audit_planes}_test.exs`.

## S5 — Kill-restart discipline (carried forward, all lanes)

Any test taking a supervised child down restores it synchronously (`try/after` + checked
restart + liveness + state verification) before reporting; `on_exit`-only restore is a
defect. Canonical implementations remain the landed lens7 fix and engine-kill court.

## S6 — Honesty register / final-text authority (carried forward: lane 20)

Exactly one gap block in release notes; per-lane proposals reconcile to lane 20 (DoD
matrix) so the census sentence matches register state at wrap.

## S7 — Probe vs court vocabulary (carried forward: lanes 18 / 21)

Only `scripts/mutation_court.py` and the phase-structured courts (BEFORE/KILL/RESTORE /
wire-tier sweep) are "courts." The `scripts/shim_court/` harness (lane 21) is a **shim
court** — phase-structured, receipt-bearing, but stamped distinct from full-court protocol
in `docs/BENCHMARKS.md`. No doc may blur the vocabulary; lane 18 arbitrates.

## S8 — Seed-detection discipline for docs citing digests/counts (carried forward, all lanes)

Any doc restating a digest, count, or gate-witness number recomputes it at landing time.
Restated values in WO docs are as-of-authoring. Lane 07's query CLI (02-receipts-query-service)
is the preferred consumer: query, don't restate.

## S2 / S4 / S9 — retired

S2 (GAP receipt-file gate), S4 (justfile split lanes 12/14), S9 (ggen template hash law)
were v26.10.14-specific. S9's underlying law (hash-pinned generated files regenerate via
the generator, never hand-edited) remains standing doctrine; no v26.10.15 lane touches the
ggen templates. Re-open only on re-witnessed failure.

## T1 — `scripts/substrate_client.sh` / `test/support/substrate_client.exs` (lanes 01 / 03 / 04 / 05 / 15 / 17 / 23)

- **Owner:** lane 01 defines the client (identity check, fail-fast, `:substrate_leak`
  guard, prefix view wiring).
- **Consumers:** 03 (port-elimination pre-flight), 04 (mode discrimination witness), 05
  (auto-routing), 15 (fast pre-flight), 17 (superfan checks), 23 (proxy client).
- **Rule:** no consumer forks the client. Pre-landing of 01, a consumer implements behind
  a local seam and switches in the same release. Fail-fast semantics
  (`SMALT_SUBSTRATE_ALLOW_STALE` opt-in only) are lane 01's contract; consumers may not
  weaken them.

## T2 — Prefix law `<lane> ::= [a-z0-9]{1,8}` / `prefix = "s" <lane> "-"` (lanes 02 / 05 / 23)

- **Owner:** lane 02 (`Smalt.Store.namespace/1` + sweep grammar).
- **Consumers:** 05 (auto-routing mints prefixes), 23 (proxy routes by prefix), all
  daemon-mode lanes at flip time.
- **Rule:** prefix grammar changes are lane 02's alone; consumers consume. Lane 23's proxy
  must route on the same grammar — a divergent prefix parser is a defect.

## T3 — `justfile.d/08-slice.just` + `tests:` blocks (lanes 13 / 25 / all)

- **Owner:** lane 13 (slice recipe + `## tests:` grammar per WO-04 §3.1).
- **Consumers:** every lane's WO doc (each owns its own `tests:` block content); lane 25
  (adds `:quarantine` tag semantics to the grammar — additive, owner-approved).
- **Rule:** lane 13 may retrofit missing `## tests:` blocks; a lane whose slice contract
  and `_LANES.md` disagree — `_LANES.md` wins, the WO doc is the bug (WO-04 §3.1).

## T4 — `scripts/wave_telemetry.sh` store + recipe (lanes 06 / 27)

- **Owner:** lane 06 (schema evolution, `justfile.d/19-wave-telemetry.just`).
- **Consumer:** lane 27 (adoption: every lane's exit emits rows; mandatory lane exit).
- **Rule:** lane 27 enforces adoption, does not change the schema; lane 06 does not gate
  adoption timing. Row store is append-only JSONL; no consumer rewrites history rows.

## T5 — Receipt query CLI vs. index writers (lanes 07 / 08 / 19)

- **Owner:** lane 07 (`scripts/receipts.py` — the read/query layer, no second store).
- **Consumers:** lane 08 (regeneration recipes stay .md writers only, never read as truth),
  lane 19 (superfan gates consume the CLI, not grep).
- **Rule:** the query layer never writes state and never reads `RECEIPTS.md`/`INDEX.md`
  as source of truth; the writers never cache across invocations. A consumer caught
  grepping receipts ad hoc is a drift defect — route through the CLI.
