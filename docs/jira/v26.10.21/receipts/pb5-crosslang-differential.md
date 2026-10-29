# PB-5 — Cross-Language Differential: Erlang FOND/POWL Runner vs Smalt.POWL2.Executor

Context: solo

- **Date**: 2026-10-21
- **Lane**: pb5 (bench)
- **Subject**: `lib/smalt/pipeline/smalt_fond_powl_runner.erl` (Erlang, gen_statem)
  vs `lib/smalt/powl2/executor.ex` (Elixir, Task.async partial-order kernel)
- **Toolchain**: OTP 29.1.2 / Elixir 1.20.4-otp-29 (pinned `popcorn_demo/.tool-versions`),
  MIX_BUILD_ROOT=_build-fondrun (`mix run --no-compile --no-start`)
- **Machine**: Apple M3 Max, 16 cores, 48 GB, Darwin 26.2
  (`{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.20.4","otp":"29","darwin":"26.2"}`)
- **Plan**: identical 16-step linear settlement plan (atoms `pb5_t001..pb5_t016`),
  deterministic contingency (no 412 loopbacks), n=200 measured runs per engine
  after one warmup run each.
- **Harness**: `scripts/bench/pb5_crosslang.exs` + `scripts/bench/pb5_crosslang.sh`
  (sources `scripts/bench/lib.sh`, emits through `bench_emit`).
- **Result file**: `tmp/bench/pb5-crosslang.jsonl`
- **Context**: solo
**Standing**: PARTIAL_ALIVE (measured-only differential; no promotion executed)

## Gate results (DIRECTIVES promotion-rule shape — measured, not promoted)

| Gate | Metric | Erlang runner | POWL2 Executor | Winner |
|---|---|---|---|---|
| A — orchestration cost (caller-side reductions/step, median) | reductions/step | 239.31 (median 3,829 total for 16 steps) | 964.31 (median 15,429) | **Erlang runner** (4.03x fewer caller reductions) |
| B — wall/orchestration (n=200) | p50 / p95 / p99 (ms) | 0.001 / 0.102 / 0.192 | 0.087 / 0.108 / 0.158 | **Erlang runner** (~87x p50; ~1.06x p95) |
| B — throughput (mean-based, n=200) | ops_per_sec | 104,166.7 | 11,057.7 | **Erlang runner** (9.4x) |
| C — receipt byte-identity | merkle over the same 35-event ledger through both seal paths | `AC94479A82A0AF0699B25F1638BEF65ACD8C4C3BC858A1D8EE69B62DA4413AC3` | `AC94479A82A0AF0699B25F1638BEF65ACD8C4C3BC858A1D8EE69B62DA4413AC3` (identical) | **TIE — byte-identical** |

Gate C detail: the runner's own receipt merkle, a direct
`smalt_fond_seal:seal/1` over the reconstructed canonical ledger, and an
in-independent Elixir mirror of the documented algorithm all produce the
identical 32-byte digest. Deterministic `term_to_binary` + the OTP-29
order-fingerprint gate make the seal byte-reproducible across languages.

## Typed findings (honest, errors included)

1. **Runner completion-protocol race (Erlang side, NEW finding)** — 98/200
   measured runs (49%) returned `{pipeline_crash, :normal}` on a SUCCESSFUL
   pipeline. Cause: in `smalt_fond_powl_runner:run/1`, the gen_statem sends
   `pipeline_complete` and then `{stop, normal}`; the spawner waits on both
   `{pipeline_complete, Receipt}` and `{'DOWN', M, process, P, Reason}` from
   different senders, so under loop load the DOWN can be delivered/selected
   first and `:normal` exit is misreported as a crash. The landed court
   (`test/pipeline/fond_powl_runner_court_test.exs`) does not observe this
   because single-shot runs rarely lose the race. Fix direction (not applied
   by this lane): flush `pipeline_complete` before honoring DOWN, or match on
   `{'DOWN', M, process, P, normal}` as success-equivalent. This is a
   correctness bug, not a perf divergence; it is measured and reported here,
   not fixed.

2. **Seal mirror leaf-order trap** — the faithful Elixir mirror must stream
   leaves in REVERSED `maps:fold` order (`leaves/1` accumulates `[Leaf|Acc]`),
   not `Enum.sort` order and not raw fold order. Both earlier attempts
   produced digests that diverged from the Erlang seal — a real byte-divergence
   would have been typed and reported; the mirror was corrected until the
   differential was byte-identical. Candidate parity trap for any future
   Elixir seal consumer.

3. **Gate A caveat**: the runner's caller-side reductions are near-zero
   because all pipeline work runs in the spawned gen_statem (child-process
   work is invisible to the caller's `statistics(:reductions)` delta); the
   Executor's admission (`Reticle.admit/1`) plus wave Task spawns run in the
   calling process. The comparison is orchestration overhead, not total work.
   Total-work reds would require tracing; out of lane scope.

## Commands

```
$ bash scripts/bench/pb5_crosslang.sh        # exit 0
--- machine spec (just bench-machine equivalent) ---
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.20.4","otp":"29","darwin":"26.2"}
```

```jsonl
{"lane":"pb5","surface":"erlang_runner","op":"settlement_orchestration","n":200,"ops_per_sec":104166.7,"p50_ms":0.001,"p95_ms":0.102,"p99_ms":0.192,"errors":98,"machine":{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.20.4","otp":"29","darwin":"26.2"}}
{"lane":"pb5","surface":"powl2_executor","op":"settlement_orchestration","n":200,"ops_per_sec":11057.7,"p50_ms":0.087,"p95_ms":0.108,"p99_ms":0.158,"errors":0,"machine":{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.20.4","otp":"29","darwin":"26.2"}}
```

## Falsifiers

- Re-run `bash scripts/bench/pb5_crosslang.sh` — gate C must remain
  byte-identical (`AC94479A...C3` for all three digests) and the runner's
  error count must be reported honestly (observed 49/200-class race rate).
- Any change to `smalt_fond_seal` iteration/pairing breaks gate C loudly
  (mirror vs seal digests diverge).

## Standing

PARTIAL_ALIVE — differential measured and receipted; byte-identity gate
PASSES; orchestration gates measured with the Erlang runner ahead on p50/ops
and executor ahead on tail (p99 158µs vs 192µs); no promotion executed (and
the runner's 49% completion-protocol race makes the Erlang runner ineligible
for any promotion until the race is fixed and re-measured).

---

## UPDATED 2026-10-21 (PB5FIX lane) — race cured upstream, gates re-measured

- **Scope note**: the owning FONDRUNNER lane landed the completion-protocol fix
  upstream mid-flight (single-sender protocol: the FSM carries the receipt out
  as its exit reason, `{stop, {completed, Receipt}}`, and `run/1` waits on
  exactly one `{'DOWN', M, process, P, Reason}` message — no second sender, no
  race window). This lane therefore did NOT edit
  `lib/smalt/pipeline/smalt_fond_powl_runner.erl`; it executed the narrowed
  scope: 500-run false-positive court, 3-way byte-identity re-verification,
  and the gate-table re-run.

### Court — 500 sequential runs (OTP 29.1.2, erlc-compiled `lib/smalt/pipeline/*.erl`)

```
COURT leg1 runs=500 ok=500 crash_normal_fp=0 other=0 deterministic=true
COURT leg2 fail_closed=ok retries=11
COURT leg2b cyclic_fail_closed=ok
COURT leg3 seal_deterministic=true
```

- leg 1: 500/500 `{ok, Receipt}`, **zero `{crash, :normal}` false-positives**
  (prior rate: 98/200), all 500 receipts share one merkle (determinism).
- leg 2/2b: fail-closed preserved — forced 412 exhaustion still returns
  `{crash, {fond_loop_bound_exhausted, ...}}` at retries=11; cyclic plan still
  returns `{crash, {cyclic_plan, ...}}`. A genuine non-normal DOWN is still a
  crash; only the false-positive channel is gone.
- leg 3: seal determinism across fresh processes: true.
- Existing ExUnit court re-run: `mix test test/pipeline/fond_powl_runner_court_test.exs`
  → **7 passed** (0 failures).

### Gate C — byte-identity re-verified (3-way)

```
PB5_RESULT erl_merkle=AC94479A82A0AF0699B25F1638BEF65ACD8C4C3BC858A1D8EE69B62DA4413AC3
PB5_RESULT mirror_digest=AC94479A82A0AF0699B25F1638BEF65ACD8C4C3BC858A1D8EE69B62DA4413AC3
PB5_RESULT erl_direct_digest=AC94479A82A0AF0699B25F1638BEF65ACD8C4C3BC858A1D8EE69B62DA4413AC3
PB5_RESULT byte_identity=true steps_ex=16 phi=16 status=:completed
```

Runner merkle = `smalt_fond_seal:seal/1` = independent Elixir mirror: identical
32-byte digest, same value as the original table (AC94479A...AC3). Gate C holds.

### Gate table re-run (legs A/B, n=200 each, driver exit 0)

```
$ bash scripts/bench/pb5_crosslang.sh        # exit 0
--- machine spec (just bench-machine equivalent) ---
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.20.4","otp":"29","darwin":"26.2"}
```

| Gate | Metric | Erlang runner (fixed) | POWL2 Executor | Winner |
|---|---|---|---|---|
| A — orchestration cost (caller reds/step, median) | reductions/step | 3097.31 (median 49,557) | 950.81 (median 15,213) | Executor (see caveat) |
| B — wall (n=200) p50/p95/p99 (ms) | | 0.456 / 0.54 / 0.609 | 0.084 / 0.109 / 0.132 | Executor on p50/ops; runner tail 0.609 vs 0.132 ms — Executor |
| B — throughput | ops_per_sec | 2,117.5 | 11,426.0 | Executor (5.4x) |
| C — receipt byte-identity | 3-way merkle | `AC94479A...AC3` | same (identical) | **TIE — byte-identical** |

**Errors: 0/200 both engines** (was 98/200 runner). The correctness bug is closed.

### Typed finding (honest deltas, not hidden)

The fixed runner's gate A/B numbers moved against it versus the pre-fix table:
p50 0.001→0.456 ms, caller reds/step 239→3097. Cause: `{stop, {completed, Receipt}}`
is an abnormal exit, so gen_statem emits a **termination error report on every
run**, rendered synchronously through the caller's group leader inside the
timing window (the driver's stderr-suppression does not stop the logger; the
1.1 MB of `** State machine ... terminating` reports per 500-run court is the
receipt). This is a real cost of the landed single-sender protocol, reported
here, not fixed by this lane (an explicit `{pipeline_completed, P, Receipt}`
message + `demonitor(...,[flush])` with DOWN-normal-as-crash would remove the
per-run report; that is the owning lane's call).

### Updated standing

ALIVE for the correctness claim (race closed, 0/500 false positives, byte-identity
holds, fail-closed crash paths intact); the promotion ineligibility in the
original standing line is lifted. Perf standing unchanged from this table:
executor ahead on orchestration p50/ops; runner still ahead on nothing measured
post-fix — the per-run termination report dominates. Receipt supersedes the
finding-1 fix-direction proposal (fix landed upstream, differently: exit-reason
protocol, not receive-loop disambiguation).
