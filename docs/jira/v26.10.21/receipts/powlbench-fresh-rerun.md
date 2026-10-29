# POWLBENCH fresh re-run + adversarial non-vacuity leg (PB-1..6 family)

**Standing:** **PARTIAL_ALIVE** — fresh measured baseline + non-vacuity proven by
mutation; one gate breach typed honestly (see §3)

Date: 2026-10-21 · Lane: bk5 (bench) · Context: solo

## 1. Inventory premise correction

The dispatch premise ("PB-1..6 receipts not landed") is **stale**. All six
receipts exist on disk with standing lines and jsonl artifacts:

| PB | receipt | standing |
|---|---|---|
| PB-1 | `receipts/pb1-fond-loop-latency.md` | PARTIAL_ALIVE |
| PB-2 | `receipts/pb2-reductions-denominator.md` | PARTIAL_ALIVE |
| PB-3 | `receipts/pb3-executor-ceiling.md` | PARTIAL_ALIVE |
| PB-4 | `receipts/pb2-reductions-denominator.md` + `receipts/pb4-merkle-dual-path.md` | REFUTED-as-noise |
| PB-5 | `receipts/pb5-crosslang-differential.md` | PARTIAL_ALIVE |
| PB-6 | `receipts/pb6-dual-boundary.md` | family typed in VALIDATION.md |

(`RECEIPTS.md` rows 94–99 index all six; `_LANES.md` row 85 is itself stale —
it still reads "(dispatched; receipts not yet landed)" while `VALIDATION.md`
rows 127–131 hold the same items already typed.)

## 2. Fresh POWLBENCH re-run (measured, no operator-asserted figures)

Harness: `tmp/bench/powl_native_face.exs` (in-process, real ETS ChangeFeed,
Executor over pre-admitted reticle model, execute-only; 3 legs).

Environment: pinned toolchain asdf `erlang/29.1.2` + `elixir/1.20.4-otp-29`,
`MIX_BUILD_ROOT=_build-bk5` (fresh compile), repo HEAD `dfc42ea`.
Machine: Apple M3 Max, 16 cores, 48 GB, macOS 26.2.

Embedded command output (fresh baseline, stderr ROW capture):

```text
$ grep '^ROW ' tmp/bench/powl-native-face-fresh-raw.log
ROW {"lane":"powlbench","surface":"powl2-native","op":"point_read_etag3","n":10000,"ops_per_sec":626762.8,"p50_ms":0.001,"p95_ms":0.002,"p99_ms":0.004,"errors":0,"min_us":1,"max_us":35}
ROW {"lane":"powlbench","surface":"powl2-native","op":"cas_put_if_match_200","n":10000,"ops_per_sec":298080.4,"p50_ms":0.003,"p95_ms":0.004,"p99_ms":0.006,"errors":0,"min_us":2,"max_us":1503}
ROW {"lane":"powlbench","surface":"powl2","op":"executor_settlement_4step","n":200,"ops_per_sec":9413.1,"p50_ms":0.029,"p95_ms":0.077,"p99_ms":0.373,"errors":0,"min_us":26,"max_us":12367}
```

Artifacts: `tmp/bench/powl-native-face-fresh.jsonl` (3 rows, errors=0),
raw log `tmp/bench/powl-native-face-fresh-raw.log`.

## 3. AR-PROD-05 gate check on the fresh numbers (typed, not smoothed over)

AR-PROD-05 gate: 4-step settlement P99 ≤ 100 µs (falsifier >200 µs). Cited
figure was 74 µs p99.

**Fresh run: p50 29 µs, p95 77 µs — but p99 373 µs (max 12.4 ms outlier
tail).** The fresh p99 **exceeds both the 100 µs gate and the 200 µs
falsifier threshold on this run**. p50/p95 reproduce the cited regime
(p50 29 µs vs 30 µs cited); the tail does not. Typed causes, in order of
plausibility: (a) this run executed on a machine under concurrent lane load
(compiler + sibling beams live during the run), and tail percentiles at n=200
are dominated by scheduler preemption; (b) n=200 gives a coarse p99 (≈2
samples). This is a **gate-breaching observation on the fresh evidence, not a
gate pass** — AR-PROD-05's "within gate on the landed evidence" now rests on
the earlier run; the fresh re-run is the loudest data point against it and
belongs in the register until a quiet-machine re-run (per the `just
quiet-check` precondition) re-adjudicates.

## 4. Adversarial non-vacuity leg (2× step-count mutation)

Mutant: `tmp/bench/powl_native_face_x2steps_MUTANT.exs` — the settlement
PartialOrder mutated from 2 waves (cg ∥ sign,pub) to a sequential 6-node
chain (cg → t1 → t2 → t3 → t4 → t5): 2×+ per-orchestration step count, same
legs otherwise. Marked in-file as an adversarial mutant.

```text
$ grep '^ROW ' tmp/bench/powl-native-face-mutant-raw.log
ROW {"op":"executor_settlement_4step_MUTANT_x2steps","n":200,"ops_per_sec":7232.7,"p50_ms":0.113,"p95_ms":0.163,"p99_ms":0.234,"errors":0,"min_us":95,"max_us":3611}
```

Artifacts: `tmp/bench/powl-native-face-mutant.jsonl`.

**The numbers moved**: settlement p50 29 → 113 µs (3.9x), min 26 → 95 µs
(3.7x), throughput 9,413 → 7,233 ops/s. A bench whose numbers did not move
under the step-count mutation would have been vacuous; this one is not.
(The mutant p99 234 µs sits *below* the baseline's noise-inflated 373 µs —
consistent with the tail being machine-load noise rather than intrinsic
orchestration cost, which further supports the §3 typing.)

## 5. Replay

```bash
export PATH=~/.asdf/installs/erlang/29.1.2/bin:~/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-bk5 mix run tmp/bench/powl_native_face.exs 2>tmp/bench/powl-native-face-fresh-raw.log
grep '^ROW ' tmp/bench/powl-native-face-fresh-raw.log | sed 's/^ROW //' > tmp/bench/powl-native-face-fresh.jsonl
# mutant:
MIX_BUILD_ROOT=_build-bk5 mix run tmp/bench/powl_native_face_x2steps_MUTANT.exs 2>tmp/bench/powl-native-face-mutant-raw.log
grep '^ROW ' tmp/bench/powl-native-face-mutant-raw.log | sed 's/^ROW //' > tmp/bench/powl-native-face-mutant.jsonl
```

## 6. Falsifier

A quiet-machine re-run (`just quiet-check` precondition) where the 4-step
settlement p99 lands ≤100 µs flips AR-PROD-05 back to within-gate on fresh
evidence; a run where p50 also exceeds 100 µs (not just the tail) would
refute the "gate breach is tail noise" typing and escalate AR-PROD-05 to
failing.
