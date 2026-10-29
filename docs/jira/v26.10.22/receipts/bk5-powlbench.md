# BK-5 POWLBENCH fresh re-run (PB-1..6)

**Standing:** **PARTIAL_ALIVE** — PB-1/2/3/5/6 measured fresh end-to-end with 0
errors across all lanes; PB-4 typed BLOCKED (its own ground-truth identity
court refuses on the fresh tree)

Date: 2026-10-22 · Lane: bk5 · Context: solo

Environment: pinned asdf `erlang/29.1.2` + `elixir/1.20.4-otp-29`; per-lane
`MIX_BUILD_ROOT` (`_build-bk5`, `_build-pb3`, `_build-bk6`); repo `main`.
Machine (every run): `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.20.4","otp":"29","darwin":"26.2"}`

## PB-1 — FOND contingency-loop latency sweep — ALIVE

Driver: `scripts/bench/pb1_fond_sweep.sh` (native leg self-contained beam; SDK
leg rides the lane-b1 private substrate, TLS twin 39014). **Full run this
window: driver exit 0, 22/22 rows** in `tmp/bench/pb1-fond-sweep.jsonl`
(11 native + 11 SDK), 0 errors both legs. Selected rows:

```text
{"contention_pct":0,  "op":"settle_r0", "n":150,"ops_per_sec":25239.78,"p50_ms":0.033,"p95_ms":0.072,"p99_ms":0.121,"errors":0,"retries_forced":0,"surface":"fond-powl2-native"}
{"contention_pct":50, "op":"settle_r5", "n":150,"ops_per_sec":11286.68,"p50_ms":0.079,"p95_ms":0.145,"p99_ms":0.172,"errors":0,"retries_forced":5}
{"contention_pct":100,"op":"settle_r10","n":150,"ops_per_sec":6528.55,"p50_ms":0.150,"p95_ms":0.240,"p99_ms":0.299,"errors":0,"retries_forced":10}
```

Throughput falls monotonically 25.2k → 6.5k ops/s (native) across 0→100%
forced-retry contention; p50 33 → 150 µs. SDK leg (@azure/cosmos over the TLS
twin, N=150/point): the original run reported `injection_failures=170` at
every contention point ≥10% with note `IF-MATCH-IGNORED` — **REFUTED** by
`receipts/kdim-ifmatch-row.md`: the probe used `ifMatchEtag`, a nonexistent
@azure/cosmos 4.10.1 option, so the If-Match header never left the client.
Corrected leg (`accessCondition: { type: "IfMatch", condition: etag }` in
`scripts/bench/pb1_cosmos_sdk.mjs`, fresh full-sweep rerun 2026-10-22, driver
exit 0, 22/22 rows, receipt `receipts/pb1sdkfix-rerun.md`): `injection_failures=0`
at all 11 contention points, **real 412 conflicts witnessed** — conflicts=37400
across the sweep (2100/point at ≥10% contention), 0 unexpected errors, 0
errors; SDK throughput 280 ops/s at r0 → 30 ops/s at r10, p50 3.56 → 29.2 ms
(the monotone fall is the injected retry tax, now actually on the wire).
Native leg rows above are unchanged. Typed ALIVE[divergence-refuted].

Note on process: two earlier driver attempts this window failed at
`bench_boot b1` with `TYPED-TIMEOUT(124)` because `lib/smalt/messaging/kafka/conn.ex`
was mid-edit by the concurrent Kafka lane (`undefined function parse_fetch/2`,
`conn.ex:460`, log `docs/tmp/bench-substrate-b1.log`); the run above is the
third attempt after that file compiled at HEAD.

## PB-2 — reductions-per-workflow-step denominator — ALIVE

Command: `MIX_BUILD_ROOT=_build-bk5 mix run --no-start scripts/bench/pb2_reductions_step.exs`
(log artifact `tmp/bench/pb2-v261022.log`). Verbatim stage lines:

```text
htn_decompose: 540 reductions/txn, 1ms total
fond_synthesize: 1200 reductions/txn, 1ms total
graph_validation: 580 reductions/txn, 1ms total
execute_primitive_step: 13017 reductions/txn, 1363ms total
receipt_seal: 16403 reductions/txn, 4082ms total
receipt_seal_alone: 3371 reductions/txn, 118ms total
fond_runner_total: 41119 reductions/txn, 98ms total
```

The receipt_seal row (16,403 red/txn incl. pipeline setup) vs
receipt_seal_alone (3,371 red/txn) reproduces the prior receipt's denominator
split; the 8-step plan settles through the real gen_statem runner in 98 ms.

## PB-3 — POWL2.Executor concurrency ceiling — ALIVE

Command: `MIX_BUILD_ROOT=_build-pb3 mix run --no-start scripts/bench/pb3_executor_ceiling.exs`.
Result file `tmp/bench/pb3-executor-ceiling.jsonl` (8 rows, fresh 2026-10-22).
First attempt (app started) failed typed on `{:listen_failed, 9092, :eaddrinuse}`
— Kafka port held by a sibling lane; rerun with `--no-start` (the lane is
in-kernel and needs no listeners). Rows:

```text
N=64   wall_ms=41   errors=0 p50=40   p99=40
N=256  wall_ms=250  errors=0 p50=238  p99=249
N=512  wall_ms=426  errors=0 p50=412  p99=422
N=1024 wall_ms=1436 errors=0 p50=1356 p99=1414
N=2048 wall_ms=1124 errors=0 p50=986  p99=1010
N=4096 wall_ms=1709 errors=0 p50=1166 p99=1185
N=8192 wall_ms=8221 errors=0 p50=5950 p99=5991
wall_level=unreached-at-8192 total_errors=0
```

No error cliff through N=8192 concurrent 4-step settlements — the in-kernel
executor ceiling stays unreached at the sweep's top, matching the prior
"clean through L4096, wall at 8192" wire-side typing now moved further out.

## PB-4 — merkle dual-path seal identity — BLOCKED (own court fails)

Harness `scripts/bench/pb4_merkle_dual.exs` (relocated from tmp/ by PB4-T) runs a ground-truth court before
benchmarking: its local O(n) fold replica of `ReceiptEngine.seal_receipt/3`
must be byte-identical to the real seal over a live DETS run at n=10, else
`System.halt(1)`. On the fresh tree the court REFUSES:

```text
FATAL: local current-path replica diverges from real seal_receipt on live DETS
replica: %{ signature: <<255,107,244,36,159,91,83,137,217,64,165,45,63,17,46,41,216,48,...>>, ... }
real:    %{ signature: <<...>>, run_id: "pb4-bench", ... }
```

Full failure dump: `tmp/bench/pb4-v261022.log`. Command:
`PB4_BUILD_ROOT=_build-bk6/dev elixir tmp/bench/pb4_merkle_dual.exs` (exit 1);
also reproduced via `mix run` (same FATAL), so it is not a build-root skew
artifact. No bench numbers were emitted — the harness correctly refuses to
benchmark a variant that is not byte-identical. Typed `BLOCKED[identity-court-refusal]`:
the replica/variant in the harness (not lib/) diverges from current
`Smalt.PPlan.ReceiptEngine` behavior; owner must re-derive the replica before
any PB-4 number is admissible. Prior standing REFUTED-as-noise is unchanged.

## PB-5 — cross-language differential (Erlang runner vs POWL2 Executor) — ALIVE

Command: `MIX_BUILD_ROOT=_build-bk5 mix run --no-compile --no-start
scripts/bench/pb5_crosslang.exs`, rows emitted into
`tmp/bench/pb5-crosslang.jsonl` via the driver's own `bench_emit` convention
(staged log `tmp/bench/pb5-staged-v261022.log`). Rows:

```text
{"lane":"pb5","surface":"erlang_runner","op":"settlement_orchestration","n":200,"ops_per_sec":1788.8,"p50_ms":0.528,"p95_ms":0.725,"p99_ms":0.831,"errors":0}
{"lane":"pb5","surface":"powl2_executor","op":"settlement_orchestration","n":200,"ops_per_sec":8410.8,"p50_ms":0.103,"p95_ms":0.155,"p99_ms":0.198,"errors":0}
```

POWL2 Executor holds its ~4.7x differential over the plain Erlang FOND runner
(8,411 vs 1,789 ops/s; p50 103 µs vs 528 µs) — reproduces the Oct-21
differential within noise.

## PB-6 — dual-boundary settlement walk (wire vs native) — ALIVE

Substrate: private TLS twin 39174 (`MIX_BUILD_ROOT=_build-bk6 MIX_ENV=test`,
repo dev certs), booted fresh this window. Command:
`SMALT_TLS_CERTFILE=$PWD/.smalt/tls/dev-cert.pem
SMALT_TLS_KEYFILE=$PWD/.smalt/tls/dev-key.pem MIX_BUILD_ROOT=_build-bk6
MIX_ENV=test mix run scripts/bench/pb6_dual_boundary.exs` (exit 0).
Result file `tmp/bench/pb6-dual-boundary.jsonl` (fresh rows 6-10 of the file —
the harness appends; earlier 5 rows are the Oct-21 run). Per-step boundary tax:

```text
1-lease    wire_p50=0.4571ms  wire_p95=0.7024  native_p50=0.055ms  tax=+0.402ms  (8.3x)
2-validate wire_p50=0.3664ms  wire_p95=0.5582  native_p50=0.324ms  tax=+0.042ms  (1.1x)
3-cas      wire_p50=0.4288ms  wire_p95=0.6464  native_p50=0.048ms  tax=+0.381ms  (8.9x)
4-seal     wire_p50=0.4300ms  wire_p95=0.6519  native_p50=0.359ms  tax=+0.071ms  (1.2x)
5-observe  wire_p50=0.3709ms  wire_p95=0.5554  native_p50=1.993ms  tax=-1.622ms  (0.2x)
```

Wire leg N=300 (+20 warmup), 0 wire errors; native leg N=5000 (+200 warmup),
0 errors. The observed tax shape reproduces Oct-21 (lease/CAS pay ~9x
boundary tax; observe is net-negative — native CDC drain exceeds one wire
round-trip).

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"; cd /Users/sac/smalt
# PB-1 (full driver: native + SDK legs):
MIX_BUILD_ROOT=_build-bk5 bash scripts/bench/pb1_fond_sweep.sh
# PB-2:
MIX_BUILD_ROOT=_build-bk5 mix run --no-start scripts/bench/pb2_reductions_step.exs
# PB-3:
MIX_BUILD_ROOT=_build-pb3 mix run --no-start scripts/bench/pb3_executor_ceiling.exs
# PB-4 (currently refuses; see section above):
PB4_BUILD_ROOT=_build-bk6/dev elixir tmp/bench/pb4_merkle_dual.exs
# PB-5:
MIX_BUILD_ROOT=_build-bk5 mix run --no-compile --no-start scripts/bench/pb5_crosslang.exs
# PB-6 (boot private TLS twin 39174 first):
SMALT_TLS_CERTFILE=$PWD/.smalt/tls/dev-cert.pem SMALT_TLS_KEYFILE=$PWD/.smalt/tls/dev-key.pem \
  MIX_BUILD_ROOT=_build-bk6 MIX_ENV=test mix run scripts/bench/pb6_dual_boundary.exs
```

## Falsifier

- PB-1: a rerun whose SDK leg shows `injection_failures=0` across all
  contention points refutes the IF-MATCH-IGNORED divergence witness —
  SATISFIED by the corrected-leg rerun (`receipts/pb1sdkfix-rerun.md`,
  0/170→0 at every point, conflicts=37400 real 412s); a rerun
  where the native 25k→6.5k contention slope inverts would refute the
  monotone contention-cost law.
- PB-4: a run where the identity court passes (ground-truth line
  `ground-truth: local replica + variant byte-identical to real seal_receipt
  (live DETS, n=10)`) re-opens the bench; until then any PB-4 number is
  inadmissible.
