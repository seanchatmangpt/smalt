# i22 — pair-context lane: court leg composition T1/T2 back-to-back x2

- **Lane**: bench-runner pair-context, repo `/Users/sac/smalt`
- **Date**: 2026-10-18
- **Standing**: SUSPECT — acceptance (4/4 clean legs) NOT met; 2/4 legs clean, both T1 full-suite legs carried failures
- **Tree**: main @ 6d84ca7 + in-flight lane edits (test/compliance/c1_arm.exs et al. modified, uncommitted)

## Protocol

After the fix receipts landed (HEAD 6d84ca7: r246 attempt-4 + i21d-store-clear-async;
r245 T3 teardown fix), reproduce the court's actual leg shape back-to-back on one
private build root `_build-ft-pair`:

1. `MIX_BUILD_ROOT=_build-ft-pair mix test 2>&1 | tail -2`
2. immediately `MIX_BUILD_ROOT=_build-ft-pair mix test test/wire --include amqp_wire 2>&1 | tail -2`

Repeat 2x. No edits, no git commands that mutate state.

## Results

| run | leg | result | classification |
|---|---|---|---|
| round 0 (pre-pair) | T1 full suite | COMPILE ABORT: `TokenMissingError` test/compliance/c1_arm.exs:832 (missing `end`) | **compile-freeze from a concurrent lane's in-flight edit** — owning lane landed the fix within the ~10 min SLA (file compiles, compliance then 157/0); not a tree defect |
| round 0 (pre-pair) | T2 wire | 29 tests, 0 failures — clean | — |
| pair 1 | T1 full suite | 2655 tests, 7 props, 1 doctest, **2 failures** (455.0s) | failure names NOT captured (`tail -2` truncated; not re-run to avoid a third 8-min leg) |
| pair 1 | T2 wire | 29 tests, 0 failures — clean | — |
| pair 2 | T1 full suite | 2655 tests, 7 props, 1 doctest, **3 failures** (566.4s), log `/tmp/smalt-pair-t1-run2.log` | see below |
| pair 2 | T2 wire | 29 tests, 0 failures — consistent | — |

### Pair 2 T1 failures (classified)

1. `Smalt.ErrorCodesDocTest` "docs/ERROR_CODES.md is the byte-identical projection
   of the sources" — **deterministic doc drift** (reproduced 1/1 in isolation):
   disk doc is stale vs `scripts/gen_error_codes.py` output; the on-disk doc and the
   modified in-flight test sources in this tree disagree. Fix is `python3
   scripts/gen_error_codes.py` by the doc-owning lane — not executed here (no-edits law).
2. `Smalt.PPlanTest` "lens3 model fuzz 10000-op ... machine model" —
   `ExUnit.TimeoutError` 60000ms. **Load-class**, matches r246's "rotating load faces
   in the async corpus/fuzz suites" (WO-A NEXT_WINDOW).
3. `Smalt.DataPlane.CosmosTest` "_rid uniqueness: 10k doc creates" —
   `ExUnit.TimeoutError` 60000ms. **Load-class**, same rotating-face family.

## Verdict

- **T2 wire tier is stable**: 4/4 wire legs clean (29/0 every time, 1.3–1.6s).
- **T1 full suite is NOT two-green in this tree at this moment**: 0/2 full-suite
  legs clean (2 and 3 failures respectively). One failure per run is deterministic
  doc drift (ERROR_CODES), plus 1–2 rotating 60s-timeout load faces in the 10k-op
  fuzz/model suites — the exact cluster r246 typed as WO-A NEXT_WINDOW.
- The pair composition did NOT reach 4/4. The court's two-green gate premise
  (both legs same tree, back-to-back) is faithfully reproduced; the tree it ran on
  carries a deterministic ERROR_CODES drift, so the gate would be RED here
  regardless of the load jitter.

## Cleanup

`_build-ft-pair` removed after receipt (see lane final message for the executed
cleanup line).
