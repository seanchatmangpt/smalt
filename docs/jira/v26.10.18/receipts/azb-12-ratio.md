# AZB-12 — Absolute timing bounds → relative-ratio assertions (lane receipt)

Standing: **ALIVE** (converted, vacuity-probed ×3, loaded witness, restore fail-closed)
Subject: `test/support/ratio.ex` + 3 converted sites + `test/semantic_epoch_test.exs` scale fence
Date: 2026-10-18
Context: shared checkout, concurrent lanes; build root `_build-lane12`

## Diff

- `test/support/ratio.ex` (NEW): `time_us/1`, `calibrate/2` (median-of-5),
  `floor_us/2` (min-of-5, repeatable subjects only), `assert_ratio/3`
  (`subject_us / max(baseline_us, 1) < max`, typed flunk naming both legs).
  Contract doc locks the fence10 lesson: baseline is an INDEPENDENT path —
  never the same clause, let alone the same refusal clause, as the subject.
- `test/pplan_test.exs:986` — "measured window" fence.
- `test/lro_test.exs:1432` — cross-sub await refusal fence.
- `test/semantic_epoch_test.exs:323` — 10k-line scale fence (3 absolute bounds → paired ratio).

## Site table

| file:line | old bound | new form | k | baseline op (independent path) |
|---|---|---|---|---|
| test/pplan_test.exs:986 | `window_us < 100_000` | `assert_ratio(floor5(Task.recover()), median5(Task.get(id)), max: 50.0)` | 50.0 | `Task.get/1` single-record read (does not call `recover/0`) |
| test/lro_test.exs:1432 | `foreign_us < 100_000` | `assert_ratio(floor5(await refusal), median5(get_op read), max: 50.0)` | 50.0 | `LRO.get_op/2` authorized read (does not ride `do_await`'s `:error ->` refusal clause) |
| test/semantic_epoch_test.exs:323 | `t_uniq/t_re/t_dup < 5_000_000` (×3) | paired min-of-5 ratios (`timeline` vs raw Jason decode), `assert_ratio(..., max: 6.0)` ×3 | 6.0 | raw `Jason.decode!/1` over the same 10k-line ledger (does not call `timeline/1`) |

## Measured geometry

- pplan: clean window receipt `kill_us=6 sweep_us=13 window_us=19`
  (tmp/errc/pplan-lens2/pid-window-measurement.txt); ratio ceiling fires at
  subject > ~150 µs vs the ~3-5 µs read control.
- lro: clean refusal/read geometry well under k=50; probe measured
  subject 42 104 µs vs baseline 1 µs → RED.
- semantic: clean ratio 1.30-2.52 (host-measured, `mix run`:
  t=19.7-38.3 ms vs 15.2 ms decode median). k=6.0 = 2.4x clean ceiling.

## Inventory closure (Accept: 0 unconverted absolute bounds)

Spec pattern `assert .*(<|<=) *[0-9]+` ∩ `ms|latency|elapsed|duration` +
`:timer.tc` comparison sweep, post-conversion residue:

- `test/auth_enforce_test.exs:2105` `abs(claims["iat"] - now) <= 1` — token
  clock skew, not latency; correctness-bearing, stays.
- `test/smalt/hw_test.exs:99` — binary pattern match, not latency.
- `test/pplan_test.exs:2443` — report count, not latency.
- `test/e2e/s6_checkpoints/checkpoint_chain.exs:52` `producer_us` — reported
  in the checkpoint row, never asserted; out of scope.
- `test/data_plane/blob_hardening_test.exs` `@perf_budget_ms`/`budget_ms` —
  REVIEWED-RETAINED: B4's manifest-gated budget (runtime manifest + anchors
  derivation + min-of-reps + drift self-check at :1671). Different fence
  contract owned by the B4 lane; converting it would overwrite a re-derived
  design. Flagged for coordinator if E2 wants it ratio-converted later.

Unconverted latency bounds: **0**.

## Anti-vacuity probes (shim → RED → sha256-verified restore)

All shims marked `# SHIM-COURT`; restore verified byte-exact against the
pre-probe sha256, fail-closed (`P? CORRUPTED` branch never taken).

| probe | shim (10x-scale subject-op slowdown) | result |
|---|---|---|
| P1 `lib/smalt/pplan/task.ex` `recover/0` body | 4 MB sha256 busy compute | RED `ratio 22235.0 >= max 50.0` (subject 66 705 µs / baseline 3 µs); restore OK `f7cd65ea…` |
| P2 `lib/smalt/arm_gateway/lro.ex` notifier-deny clause | 4 MB sha256 | fence stayed GREEN — probed the WRONG clause: the foreign await rides `do_await`'s `:error ->` scoped-denial clause (the fence10 wrong-refusal-clause trap, re-witnessed) |
| P2b `do_await`'s `:error ->` clause (true subject clause) | 4 MB sha256 | RED `ratio 42104.0 >= max 50.0`; restore OK `22261942…` |
| P3 `lib/smalt/projection/semantic_epoch.ex` `timeline/1` head, 4 MB single | — | GREEN — underdosed for a ~20 ms subject (8 ms payload ≈ 0.4x); dose lesson: a probe must scale with the subject |
| P3d `timeline/1`, 400× payload (~20 s/call) | RED but via 60 s ExUnit timeout, not the fence | restore OK |
| P3e `timeline/1`, 20× payload (~1 s/call) | RED at the fence: `ratio 129.97 >= max 6.0` (subject 943 207 µs / baseline 7 257 µs) → retightened k 15→6 from measured clean geometry; P3f re-witness after retighten: `ratio 140.36 >= max 6.0`, restore OK `30a8a7aa…` |

## Falsifier (witnessed, then designed out)

First `just burn-chaos` (8 hogs, 1 round): the semantic fence went RED
**with no product change** — `ratio 11.51 >= max 6.0` (subject 651 916 µs /
baseline 56 650 µs). Root cause: single-shot subject over an independent
median baseline is not co-monotonic under desched — exactly the load-facing
half of the fence10 lesson. Fix: paired rounds, min-of-5 (the fuzz_test.exs
precedent) — each round times timeline and decode back-to-back so load hits
both legs co-monotonically; min of per-round ratios sheds spikes. Same
falsifier run also showed 8 other unrelated load flake faces (C4Blob wire
tier etc.), classified by soak.sh against FLAKE_LEDGER — not this lane's
diff.

Post-fix burn-chaos rerun: `just burn-chaos` (8 hogs) offline tier completed
2674 tests / 16 failures — **none of the three converted fences among them**
(tmp/burn-leg-20261018T230530Z.log; the 16 faces are foreign: azsim plane
suites, TLS paired-boot, stress census, canonical drift — other lanes'
in-flight edits, incl. Spark DslError compile aborts mid-tree). The same
run's wire tier leg aborted exit 2 on a foreign mid-run compile state
("Compiling 5 files" / `cas_replace` unused from a concurrent lane's
in-flight blob_storage.ex edit) — compile-abort, not a failure count; not
this lane's diff.

## Validation

- Solo combined (`pplan:986 + lro + semantic`, offline tier): 5/5 green in a
  quiet window (and 10/10 on the earlier single-shot form pre-retighten).
- `just burn-chaos` (8 yes-hogs, atom-flood 20 s, 1 x offline + wire):
  offline leg 2674 tests / 16 failures, all foreign (see Falsifier);
  all three converted fences GREEN under load. Wire tier leg aborted
  exit 2 on a foreign mid-run compile state — compile-abort, not a
  failure count, not this lane's diff. Two earlier 1-failure combined
  runs coincided with concurrent lanes' compile/test activity on the
  shared checkout (lro_test.exs was edited by another lane mid-run);
  could not be reproduced in the quiet-window 5/5 sweep, and no failure
  body was captured — disclosed as UNKNOWN, not claimed clean.
- Probe restores: sha256 byte-exact ×3 files (fail-closed check ran green).

## Disclosures

1. P2 wrong-clause probe (fence GREEN under a real slowdown shim) is itself
   the b3-fence10 §3 lesson re-witnessed: the subject clause must be
   identified from the actual control flow (`get_scoped` denies by scope
   before the notifier is ever consulted), not from the comment's story.
2. P3 dose lesson: an anti-vacuity shim must be sized relative to the
   subject op (10x of 20 ms ≈ 200 ms, not 8 ms). Two probe runs (P3, and
   the lro P2 first attempt) were non-probes before the dose/clause was
   corrected — recorded here rather than silently discarded.
3. k retighten (15→6) happened AFTER the first P3e probe; the P3f re-witness
   postdates the retighten, so the witnessed RED is against the committed
   bound.
4. `@perf_budget_ms` (blob pagination) retained absolute — see inventory
   closure. Not unilaterally converted (B4's fence contract).
5. No git operations. Build root `_build-lane12` left for the coordinator's
   `just lane-clean`.
