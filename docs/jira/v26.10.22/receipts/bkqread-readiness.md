# BK-QREAD — drain-or-seal readiness census

- **Date**: 2026-10-22 06:40 PDT
- **Lane**: BK-QREAD, repo /Users/sac/smalt (canonical checkout), read-only except this receipt
- **Standing**: **PARTIAL_ALIVE** — verdict **NOT-READY**; machine hot, 8+ lanes' tests actively running, no quiescent window
- **Context**: solo

## Verdict: NOT-READY

Three independent channels all say the machine is mid-wave, not draining:

1. **Load**: `uptime` at 06:39: `load averages: 99.96 96.63 94.36` (1/5/15 min). Sustained ~95-100 — this is a fully loaded machine, not a draining one.
2. **Beams**: 37 beam.smp processes. LISTEN census: 10 idle (LISTEN=0), 27 hold sockets. The one genuine substrate beam is pid 76687 (started 05:19:34, holds 9444 / 9545 / 51843). The remaining 26 socket-holding beams are lane test beams on ephemeral ports (39xxx/50xxx/6xxxx bands — lane bN port law visible: 39020/39600/39761/39890/39900/39910/40010/39210 bands). 10 truly idle beams (LISTEN=0) are candidates for `scripts/port_sweep.sh` once owners confirm.
3. **Active court/test processes**: 8 distinct lane suites in flight at census time (deduped by suite):
   - `test/internal/internal_tier_census_test.exs` ×2 (bkvc-consolidated also seen via fast_test)
   - `test/internal/bkegs1_fence_court_test.exs` ×3 (one under `MIX_BUILD_ROOT=_build-bkxprif`)
   - `test/pipeline/fond_powl_runner_court_test.exs` ×3 (`MIX_BUILD_ROOT=_build-bkratio`)
   - `test/internal/kd173r_audience_scope_court_test.exs` ×2 (`_build-bkampv`)
   - `test/internal/bkvc_consolidated_court_test.exs` (fast_test, timeout 560)
   - `test/internal/eplaw_ephemeral_boot_court_test.exs`
   - `test/internal/expl5r1_court_test.exs`
   - `test/internal/kafka_exp4_court_test.exs` ×3
   - `test/integration/wasm_sandbox_court.exs` (`_build-bkgwsskep`)
   - `tmp/bkmaa2_probe_test.exs`
   Plus a BK-BQUIET harness leg failing live (`tmp/bkbquiet/b2-run.log` at 06:40: `FAILED harness TypeError: fetch failed`, substrate pid 35274).

## Lane census

Build roots touched within the last 12 minutes (06:28-06:40) — live lanes, owners hold them:
`_build-bkcens3`, `_build-ft-75ef1f9e`, `_build-bkratio`, `_build-bkampv`, `_build-bkfondv`, `_build-bkwps2v`, `_build-bkmon2`, `_build-bkxprif`, `_build-lane-w4j`, `_build-lane-expl12b`, `_build-kd174f`, `_build-kfkc2`, `_build-bkcert`, `_build-bkf6r`, `_build-bkfkfc`, `_build-bkegs1`, `_build-rewit3`.

Landed and drainable (receipt on disk, root older than ~15 min): `_build-bkwpss2` (BK-WPSS2, landed 06:26 commit 7beaec31), `_build-bkseal3/_build-bkseal4` (05:34/05:58), `_build-expl10r/_build-expl11r/_build-expl11r2/_build-expl11r3` (05:31-05:39), `_build-maap6` (05:49), `_build-seqb` (05:54), `_build-ampf1` (05:35), `_build-expl12b`... EXPL12-B/V landed as commits 22ed3e2d/5aad5b89. KD-N1 landed (kdn1-row.md 06:39, commit a1176901). BK-CENS4 landed (bkcens4-wave4.md 06:30): census **6/6 green** on the sealed population, BK-SEAL3's census blockers all cleared.

## Required seal-precondition facts (re-read from disk receipts)

- **Last census run**: BK-CENS4 (06:30 receipt): `MIX_BUILD_ROOT=_build-bkcens4 mix test test/internal/internal_tier_census_test.exs` → `Result: 6 passed`. Census 6/6, population fence sealed at that snapshot.
- **Last full-suite result line**: BK-SEAL2 (`bkseal2-fullgreen-recheck.md`, PARTIAL_ALIVE): best completed run `Result: 764/780 passed` (second run; 16 failures classified: 5 in-flight census drift + 11 cross-lane contention, zero real defects). First run 735/739. **No quiescent full-suite green exists yet.**
- **Quiet-check**: no fresh green quiet-check receipt newer than BK-SEAL2 (05:0x). BK-BQUIET harness legs failing live as of 06:40 (fetch failed against a contended lane port) — that is evidence of non-quiet, not quiet.
- **Witness-all freshness**: no witness-all run newer than the 06:30 census; newest witness artifacts are `tmp/bkn7-witness.jsonl` (05:21), `tmp/eplaw2-b9b-witness.log` (05:10). Stale relative to the census.

## Coordinator guidance

BK-SEAL3's close condition (quiet-check PASS + census 6/6 + full-suite result line) is NOT met. Census leg is green (6/6, 06:30). Missing: a quiescent full-suite green + fresh quiet-check + fresh witness-all. With load ~100 and 8+ suites in flight, sealing now would reproduce BK-SEAL2's contention-classified failure set. Drain order: let the 8 in-flight suites land receipts, run `just lane-clean` on the landed roots, quiesce (`just quiesce`), then rerun the full suite + quiet-check + witness-all before seal.
