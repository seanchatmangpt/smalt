# BK-14 KD-143 Witness — SB rule sqlFilter persistence across recycle

**Standing:** ALIVE
- Context: solo
- Date: 2026-10-21 20:36 PDT
- KD row: KD-143 (canonical: docs/jira/v26.10.14/KNOWN_DIVERGENCES.md — status CLOSED-SIMULATED, flipped by the bk13 kd-registrar lane; this receipt reinforces the closure with the RESTART court the original FIX-2 witness lacked)
- Fix surface: `:smalt_sb_rules` now carries `persisted: true` in the generated
  `lib/smalt/store_tables.ex` registry (`Smalt.StoreTables.persisted_tables/0`,
  consumed by `Smalt.Store.DetsMirror` as its default mirror set). The flip
  originated in the ontology (ggen-marketplace
  `packs/smalt-substrate-pack/ontology.ttl`, smalt:st-smalt_sb_rules
  `smalt:persisted true`) and is landed on main as of commit 17f7c21 (concurrent
  re-manufacture wave; working tree equals HEAD for store_tables.ex at witness
  time).

## Before (defect, mechanically reproduced)

The pre-fix registry shape (mirror set without `:smalt_sb_rules`) is preserved
as a PERMANENT negative control in the court
(`test/internal/bk14_kd143_sqlfilter_persistence_test.exs`, leg 1). A
mirror over the pre-fix table set, rule PUT 201 + mirror sync, ETS drop
(recycle semantics), restore → NO sb_rules replay, GET after restore → 404.
The filter is silently dropped. This is the KD-143 recycle defect, kept
runnable so the court cannot silently rot.

## After (fix landed)

`test/internal/bk14_kd143_sqlfilter_persistence_test.exs` — 4 tests, real
Store, real ARM dispatch, real DETS files, real DetsMirror sync/restore, no
mocks, no sleeps.

Command: `MIX_BUILD_ROOT=_build-bk14 mix test test/internal/bk14_kd143_sqlfilter_persistence_test.exs --include smalt_internal`

```
Finished in 1.6 seconds (0.00s async, 1.6s sync)
4 tests, 0 failures
```

Full run exit code: 0

Legs:

1. NEGATIVE CONTROL (pre-fix registry shape): mirror without sb_rules →
   rule PUT 201, sync, ETS drop, restore → no replay, GET 404. Defect witnessed.
2. Persistence court: ARM PUT rule
   `{filterType:"SqlFilter", sqlFilter:{sqlExpression:"priority = 'high'"}}` →
   201; real `DetsMirror.sync/1` fsyncs the DETS file; rule rows deleted from
   ETS (recycle); `DetsMirror.restore/1` → `%{smalt_sb_rules: n>=1}`;
   wire GET → 200 echoing `sqlFilter.sqlExpression` AND nested
   `filter.sqlExpression`; restored filter EVALUATES post-recovery
   (subscription_admits?: match admits, non-match skips).
3. Adversarial — corrupt mirror: a non-DETS body at `smalt_sb_rules.dets` is a
   TYPED refusal (`corrupt_mirror` ArgumentError naming the table) on mirror
   boot — fail-closed, never a silent drop.
4. Adversarial — partial record: a restored rule with NO properties is a
   clean skip (typed `{:error, :invalid_filter, _}` from
   `Smalt.SbRules.compile/1`, `true_filter?/1` fail-closed false), never a
   FunctionClauseError crash on the fan-out path.

Regression: `MIX_BUILD_ROOT=_build-bk14 mix test test/integration/kd143_rules_persistence_test.exs`
→ `6 tests, 0 failures`, exit 0.

## Typed fallbacks added to lib/smalt/sb_rules.ex (this lane)

```elixir
def compile(_props), do: {:error, :invalid_filter, "non-map rule properties"}
def true_filter?(_props), do: false
```

## Lane-process receipts (disclosures)

- MIX_BUILD_ROOT=_build-bk14 used for all compile/test runs.
- The registry flip was projected via hand-application matched to the landed
  HEAD (commit 17f7c21 landed the same flip concurrently mid-lane; the
  working tree converged with it). `mix smalt.gen` could NOT be used as the
  write path: ggen_igniter.sync's terminal reactor `:verify` step runs
  `mix compile --warnings-as-errors`, which cannot pass in this tree today
  (replayed warnings from path deps ash_graphlaw/ggen_igniter + smalt's own
  lib). Witnessed tree-wide, not lane-local: today's
  `.ggen_igniter/receipts/2026-10-22.jsonl` shows 6 VERIFICATION_FAILED →
  FILES_RESTORED compensations from other lanes hitting the identical wall.
  The read-only `--check` probe is unusable as an identity oracle: it
  reports DRIFT even on the committed HEAD file (it compares the pre-`mix
  format` render). This is a generator-gate defect for the kd-registrar to
  register (not minted here — KD mints are registrar-owned).
- Compile-freeze event: a concurrent lane's in-flight edit to
  lib/smalt/sync/frame.ex broke the shared compile mid-court; resolved by
  bounded-retry (the lane landed its fix), no cross-lane edits by this lane.
- Fast_test-derived build roots ignore MIX_BUILD_ROOT; plain `mix test` with
  MIX_BUILD_ROOT=_build-bk14 was used instead (lane lease honored).
