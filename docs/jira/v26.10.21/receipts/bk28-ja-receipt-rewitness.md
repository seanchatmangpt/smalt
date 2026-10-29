# BK-28: JA parent-persisted receipt re-witness (receipt-index hygiene lane)

Repo: `/Users/sac/smalt` · Branch: `main` · Date: 2026-10-21 · Context: solo

Standing: **PASS — all 6 parent-persisted JA receipts re-derived against the current tree with
real greps; SUSPECT flag count 49 → 48 (ja1-supervision-census cleared); NO-CONTEXT on ja1/ja6
cleared; index regenerated (RECEIPTS.md + INDEX.md per window).**

## Scope and method

`python3 scripts/receipt_index.py` before: `receipts=1105 sdk=61 total=1166 suspects=49`.
The parent's expectation list (ja1/ja2/ja6/ja8/ja11/ja14 all SUSPECT) was STALE — at run time
only `ja1-supervision-census.md` carried the aggregate SUSPECT flag (no embedded command output),
and only ja1/ja6/ja7 carried NO-CONTEXT. All six named receipts were re-witnessed regardless.

Method per receipt: append a dated `## Re-witness (BK-28, 2026-10-21)` section embedding real
command output (grep exits, find counts, file:line excerpts) re-derived from the CURRENT tree;
convert the standing line to the index's explicit `- **Standing:**` form so the table reads the
honest post-JA-R status; add the missing `Context: solo` line (ja1, ja6). No prior content
deleted; no `lib/` code touched; ja7-crash-only-court.md (NO-CONTEXT, not in scope list) and
gws18/sk5-sk3/wrap1 (NO-CONTEXT, other lanes) left alone, as were all bk19/bk23-27 lane files.

## Per-receipt before → after

| Receipt | Before (flag / standing) | After (flag / standing) | Key re-derived findings |
|---|---|---|---|
| ja1-supervision-census.md | SUSPECT + NO-CONTEXT / UNKNOWN | clean / PARTIAL PASS | #1 Apim naked `spawn_link` FIXED (JA-R2: GenServer owner + heir ETS, apim.ex:46-67); #2 amqp10 unlinked ledger holder, #3/#4 Wasm.Pool/Cluster unsupervised homes, #5 lazy-start family STILL OPEN |
| ja2-let-it-crash-audit.md | no flag / UNKNOWN | clean / PASS | V1-V4 all FIXED by JA-R1 (in-code `JA-R1 (Vn)` tags at planes.ex:64, egress_router.ex:947, router.ex:3401, ledger_writer.ex:169; receipt `ja-r1-silent-violation-fixes.md`) |
| ja6-error-kernel.md | NO-CONTEXT / PASS | clean / PASS | kernel classification HELD; Store funnel + RollingCounters missing `:heir` STILL OPEN; TTV-4 journal boot replay (store.ex:62-74) shrinks Store cold-restart blast radius |
| ja8-concurrency-purity.md | no flag / PASS | clean / PASS | atom_bridge pterm→ETS FIXED (JA-R2, atom_bridge.ex:117-143); pdict/poke laws hold; cbs_router + event_grid/appconfig_events funnels remain borderline |
| ja11-behaviour-dod.md | no flag / PASS | clean / PARTIAL PASS | handle_info catch-alls 6→8 (apim.ex:67, wasm_engine_supervisor.ex:215 new); 5 double-duty violations + DetsMirror `:tick`-only clause STILL OPEN |
| ja14-release-handling.md | no flag / UNSUPPORTED | clean / PARTIAL ALIVE | hot-upgrade re-verified UNSUPPORTED (0 .appup/.relup/code_change); the open cold-restart gap LANDED as TTV-4 boot replay (store.ex:62-74, `{:stop, {:journal_replay_failed, reason}}` fail-closed boot) |

ja14 note: `find . -name '*.appup'|wc -l` → 0; `.relup` → 0; `grep -rn code_change lib/ --include='*.ex'`
→ 0 (only hits are inside the committed `lib/smalt/pipeline/erl_crash.dump` binary — itself a
repo-hygiene finding, 1.9 MB crash dump checked into lib/).

## Index output tails

Before (`2026-10-21 ~19:40 PDT`):

```
receipts=1105 sdk=61 total=1166 suspects=49
  SUSPECT: ja1-supervision-census.md (standing UNKNOWN)
  ...47 more, none JA-family...
  SUSPECT: ttv8-spec-bounds.md (standing ALIVE)
wrote .../v26.10.14..v26.10.21 RECEIPTS.md + receipts/INDEX.md pairs
```

After (final run):

```
receipts=1116 sdk=61 total=1177 suspects=48
  SUSPECT: 06-blob-x-ms-date-unvalidated.md (standing UNSUPPORTED)
  ... (ja1 no longer flagged; no JA-family SUSPECT remains)
  SUSPECT: ttv8-spec-bounds.md (standing ALIVE)
```

NO-CONTEXT in v26.10.21 after: gws18, ja7, sk5-sk3, wrap1 only (out of BK-28 scope).

## Receipts table rows (v26.10.21, after)

```
| ja1-supervis | PASS | JA-1 Supervision Census — smalt @ main (2026-10-21) |
| ja11-behavio | PASS | JA-11 Behaviour Definition-of-Done Census — branch `main` |
| ja14-release | UNSUPPORTED | JA-14 — Release Handling (hot-upgrade vs cold-restart) |
| ja2-let-it-c | PASS | JA-2: Let-It-Crash Audit — silent-violation sweep |
| ja6-error-ke | PASS | JA-6: Smalt Error Kernel — Classification & Blast Radius |
| ja8-concurre | PASS | JA-8 Concurrency Purity Audit — lib/smalt |
```

Standing-token caveat: the index vocabulary has no PARTIAL-PASS token, so "PARTIAL PASS"
standing lines render as PASS (ja1, ja6, ja11) — the receipts' own text carries the qualified
standing; the table token is the script's nearest-vocabulary projection.

## Authority cited

- `ja-r1-silent-violation-fixes.md` (JA-R1 lane; fixes for ja2 V1-V4 — landed mid-session,
  19:48 PDT; its own table row reads UNKNOWN standing, left to its lane)
- `ja-r2-apim-atom-bridge-fixes.md` (Apim GenServer owner + heir ETS + atom_bridge pterm→ETS)
- `ja-r3-ja16-defect-fixes.md` (JA-16 D1-D3)
- TTV-4 boot replay: `lib/smalt/store.ex:62-74,79-121`; court `test/integration/ttv4_journal_boot_replay_court.exs` (in-flight TTV lane)

Not committed (per lane instructions).
