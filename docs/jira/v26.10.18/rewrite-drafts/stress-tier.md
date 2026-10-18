# Stress Tier — Tagging Plan (draft, v26.10.18)

Status: DRAFT (read-only inventory; no tree edits, no git actions).
Window evidence: `docs/jira/v26.10.17/receipts/i22-pair-context.md`,
`docs/jira/v26.10.17/receipts/i22-soak-c.md`,
`docs/jira/v26.10.17/FLAKE_LEDGER.md` (rows F3, F12),
`docs/jira/v26.10.17/receipts/i21-churn-budget.md`.

## 1. Finding

T1 (`just test-offline` = `mix test`) wall time is dominated by two classes of
expensive test bodies:

**Class A — intrinsically expensive (legitimately multi-second quiet):** the
byte-identical replay/identity fences plus the regen-interleave fence.
Measured this session on HEAD 885c451, quiet machine,
`MIX_BUILD_ROOT=_build-ft-stress`, exit 0, **42 tests / 0 failures in
104.3 s body**:

- `test/semantic_projection_test.exs` (`@tag :regen_interleave`,
  `timeout: 600_000`, line ~259)
- `test/config_replay_identity_test.exs` (`@moduletag timeout: 240_000`)
- `test/store_tables_replay_identity_test.exs` (`@moduletag timeout: 300_000`)
- `test/cascade_replay_identity_test.exs` (`@moduletag timeout: 300_000`)
- `test/semconv_replay_identity_test.exs` (`@moduletag timeout: 300_000`)
- `test/smalt_registry_replay_identity_test.exs` (`@moduletag timeout: 240_000`)
- `test/smalt_ets_baseline_identity_test.exs` (`@moduletag timeout: 240_000`)
- `test/smalt_ets_composite_identity_test.exs` (`@moduletag timeout: 300_000`)

**Class B — load-class jitter victims (cheap quiet, blow the default 60 s
ExUnit timeout under suite load):** the FLAKE_LEDGER "rotating 60 s-timeout
load faces." Witnessed this window:

- `test/corpus/shacl_fuzz.exs:99` fuzz sweep — `ExUnit.TimeoutError` 60000 ms
  in `tmp/soak-c-run2.log:16654` (FLAKE_LEDGER F3 face class); quiet solo
  body 7.8 s (`test/corpus/helper.exs test/corpus/shacl_fuzz.exs`, 3 tests /
  0 failures, 9.3 s wall incl. compile).
- `test/pplan_test.exs` 10000-op model fuzz (line ~1630) and
  `test/data_plane/cosmos_test.exs` `_rid uniqueness: 10k doc creates`
  (line ~835) — both witnessed as 60 s load timeouts in
  `receipts/i22-pair-context.md` §"Verdict".

Solo re-measure of Class B this session (all exit 0): pplan full file with
`--include pplan_stress` = 73 tests / 0 failures, 4.7 s body (6.1 s wall);
cosmos file = 128 tests / 0 failures, 1.4 s body (2.8 s wall). Class B is
cheap in isolation and only breaks under T1's parallel contention — exactly
the profile the stress tier removes from T1.

## 2. Explicitly NOT tagged (inventory completeness)

- `test/amqp/fuzz_test.exs` (1..5000 maps, 1..2000 seed loops) — CPU-bound
  micro-fuzz, sub-second quiet, no FLAKE_LEDGER faces.
- `test/data_plane/audit_planes_test.exs:1755` (1..1000 Store.put loop) —
  ETS-only, sub-second.
- `test/auth_enforce_test.exs:1398` (2000-audience list) — linear, sub-second.
- `test/pplan_test.exs:942` (1..2000 spawn loop inside lens2) — bounded small.
- Existing `:pplan_stress` and `:corpus` tags stay as family labels; the new
  `@tag :stress` is added alongside them (compose, don't replace).
- Wire tier (`test/wire`) and compliance corpus — separate gates already.

## 3. Tagging plan

| # | file:line | test | class | measured evidence |
|---|---|---|---|---|
| 1 | test/semantic_projection_test.exs:259 | regen_interleave byte-identical render | A | 104.3 s cluster, this session, 42/0 |
| 2 | test/config_replay_identity_test.exs | config replay identity (moduletag) | A | same cluster |
| 3 | test/store_tables_replay_identity_test.exs | store_tables replay identity (moduletag) | A | same cluster |
| 4 | test/cascade_replay_identity_test.exs | cascade replay identity (moduletag) | A | same cluster |
| 5 | test/semconv_replay_identity_test.exs | semconv replay identity (moduletag) | A | same cluster |
| 6 | test/smalt_registry_replay_identity_test.exs | registry replay identity (moduletag) | A | same cluster |
| 7 | test/smalt_ets_baseline_identity_test.exs | ets baseline identity (moduletag) | A | same cluster |
| 8 | test/smalt_ets_composite_identity_test.exs | ets composite identity (moduletag) | A | same cluster |
| 9 | test/store_dets_test.exs:147 | restore x insert_new churn (timeout 600_000) | A (loaded 93–204 s body) | receipts/i21-churn-budget.md, FLAKE_LEDGER F12 |
| 10 | test/corpus/shacl_fuzz.exs:99 | 1000-PUT fuzz sweep (timeout 180_000) | B | tmp/soak-c-run2.log:16654 (60 s timeout); 7.8 s quiet |
| 11 | test/pplan_test.exs:1628 | 10000-op model fuzz with poison patches (timeout 180_000) | B | i22-pair-context 60 s load timeout |
| 12 | test/pplan_test.exs:1221 | 3000-op stress fuzz + interleaved recover sweeps | B | same family (pplan_stress tag already present) |
| 13 | test/pplan_test.exs:916 | 2000 replacements between kill and sweep | B | same family (pplan_stress tag already present) |
| 14 | test/data_plane/cosmos_test.exs:833 | _rid uniqueness: 10k doc creates (timeout 180_000) | B | i22-pair-context 60 s load timeout |
| 15 | test/data_plane/cosmos_test.exs:2294 | store restart replay-or-drop (timeout 150_000) | B | same contention family |

For module-level Class A files: add `@moduletag :stress` next to the existing
`@moduletag timeout:` line (keeps the timeout tag intact). For single tests:
add `@tag :stress` next to the existing `@tag timeout:` line. For rows 12–13
the `@tag :stress` line goes directly under the existing
`@tag :pplan_stress` line.

## 4. test_helper.exs diff draft

```elixir
ExUnit.configure(
  exclude: [
    :amqp_wire,
    :stress
  ]
)
```

Update the header comment block: add `:stress` to the named-exception list
with owner (v26.10.18 ERRC-Raise lane) and re-enable condition
(`mix test --include stress`); mirror in `docs/TEST_ISOLATION.md`.

## 5. justfile.d diff drafts

New module `justfile.d/28-stress.just`:

```just
# Stress tier: expensive test bodies (replay-identity fences, regen
# interleave, DETS churn, 10k-op fuzz, 1000-PUT corpus sweep) excluded from
# T1 by default via test_helper.exs. Runs sequentially in its own gate
# stage. Exit 0 pass / nonzero fail.
@test-stress:
    mix test --include stress
```

One import line in the root `justfile` (per the justfile fan-out law: lanes
add modules, never rewrite the root beyond the single import):

```just
import 'justfile.d/28-stress.just'
```

Gate wiring (implementer option; recommendation noted):

- Option 1 (recommended): add a `test-stress` stage to
  `scripts/verify_all.sh` after T1 so `just verify-all` carries it, and add
  `test-stress` to the `court:` recipe prerequisites (justfile ~line 201)
  after `test-offline`.
- Option 2: fold into `justfile.d/07-court-x2.just` legs. Rejected for now:
  court-x2 is the release gate and would run the ~2–5 min stress stage twice;
  single-run in court/verify_all suffices. Coordinator may flip.

Non-vacuity guard: the stage must be able to fail. `mix test --include
stress` on a tree where the tags did not land runs 0 tests and exits 0 — add
a count assert, e.g.

```just
@test-stress:
    mix test --include stress && test "$(mix test --include stress --dry-run 2>/dev/null | grep -c ':stress')" -gt 0
```

Simpler fail-closed form (no double run): keep the recipe plain but have the
lane receipt cite the ExUnit line "N tests" with N >= the tier's 30+ case
count; a drift-fence test can assert the tier population (see below).

## 6. T1 wall-time estimate after the tier lands

Measured inputs: full-suite T1 legs this window = 455.0 s, 566.4 s
(i22-pair-context), 393.2–603.5 s (i22-soak-c runs 1–3). Identity+regen
cluster = 104.3 s quiet body (this session). Class-B faces burn up to 60 s
each when they trip (one to two per loaded run observed).

- Quiet T1: 393 s − ~104 s ≈ **~290 s** (~4.8 min).
- Loaded T1: 455–603 s − 104 s − 60–120 s of timeout burn ≈ **~290–430 s**.
- New separate stage `mix test --include stress`: ~110 s quiet (identity
  cluster + fast Class-B bodies) to ~310 s under load (dets churn loaded tail
  dominates); sequential, so no cross-suite contention and the 60 s-default
  Class-B tests stop tripping by construction.

Net: T1 becomes a deterministic ~5-minute fence; total gate wall grows by
only the stress stage's non-overlapped tail, and FLAKE_LEDGER load faces F3 /
F12 / pplan-10k / cosmos-10k stop firing in T1 at all.

## 7. Follow-ups for the implementing lane

1. Land tags + test_helper exclude + just module (diffs above).
2. Add a tier-population fence (asserts >= 20 `:stress` cases exist) so
   silent tag loss cannot hollow the tier.
3. Record a receipt with one `mix test --include stress` run (real output)
   and update `docs/TEST_ISOLATION.md`.
4. FLAKE_LEDGER: F3/F12 rows gain "moved to stress tier" close note.
