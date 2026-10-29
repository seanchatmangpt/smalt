# BENCH-10 — pure-Erlang bench architecture skeptic audit

- **Lane**: BENCH-10 (skeptic, pure Erlang), 2026-10-21
- **Subject**: `docs/jira/v26.10.21/BENCH-ERLANG.md` (AR-BENCH-01/02) + `bench/smalt_bench_court.erl`
**Standing**: **ALIVE** — all three audit claims proven with executed probes on this machine
Context: pair (skeptic audit over BENCH-ERLANG spec + another lane's bench/smalt_bench_court.erl)
  (OTP 28 local runtime; spec file itself is corrupted mid-write, two STOP markers at lines
  53 and 69 — audit built against the task statement + landed `bench/smalt_bench_court.erl`
  + reference scripts, not the corrupted contract text).

## Note on the spec file

`BENCH-ERLANG.md` is corrupted by an editing artifact mid-write: two embedded
"STOP. Corruption recurred." markers (lines 53 and 69), a mangled AR-BENCH-01 section,
and a stub `### AR-BENOCH-01` block. The court module (`bench/smalt_bench_court.erl`)
is real and landed; the audit therefore ran against the court module, the reference
scripts (`scripts/bench/pb2_reductions_step.exs`, `scripts/bench/impl17_amqp_reductions.exs`)
and the AR-BENCH-02 gate as stated in the dispatch (caller heap Δ≤32 words).
A clean re-land of the spec is a precondition for implementation lanes.

## Verdicts (typed)

| # | Claim audited | Verdict | Corrected primitive |
|---|---|---|---|
| 1 | AR-BENCH-02 heap gate backed by `erlang:memory(total)` | **INVALID** — node-global | `erlang:process_info(self() \|\| worker, heap_size)` after double-GC, per measured process |
| 2 | `erlang:statistics(:reductions)` reds_per_op attribution | **INVALID** — node-global | `erlang:process_info(worker, reductions)` deltas around the batch, batch executed in an isolated worker |
| 3 | Per-process reductions availability (OTP 18+) | **AVAILABLE** (verified OTP 28 here; per-process since OTP 18.0 release notes) | isolated worker process + `process_info(worker, reductions)` |

## Probe 1 — node-global ≠ caller-local heap (`/tmp/bench10_probe1.escript`, exit 0)

A bench caller runs a flat-heap measured batch (`lists:seq(1,64)` x 20000) while an
unrelated process allocates 200 x 2 MB (~3.2 GB total, held) inside the measured window.

Actual output:

```
quiet:  caller heap delta = 0 words
noisy:  caller heap delta = 0 words ; erlang:memory(total) moved = 1792 MB (noisy allocated 3200 MB, window 344 ms)
unrelated alloc >100MB and node memory moved >50MB: true ; caller flat (<=32 words): true
VERDICT-1: an unrelated process allocated 3200 MB inside the measured window and
erlang:memory(total) moved 1792 MB, while the caller's own heap stayed flat (0 words).
Counterexample stands: an erlang:memory(total)-based gate cannot detect or bound the
caller's heap — node-global != caller-local.
```

Interpretation: `erlang:memory(total)` moved **1.79 GB** in the window with **zero** caller
heap movement. An `erlang:memory`-backed gate reads the wrong variable entirely: it can PASS
a claim while the caller allocated nothing and the world moved, and it can never bound the
caller's heap because it does not read it. Additional finding: without a **double** GC before
each read, the caller's own `heap_size` delta read 143 words of GC high-water noise on the
first run (the gate as written would then reject a caller that allocated nothing) — the court
module's `gc_stabilize()` (two `garbage_collect/1` calls) is necessary and sufficient here.

## Probe 2 — reductions contamination (`/tmp/bench10_probe2.escript`, exit 0)

Same batch measured quiet vs with a concurrent busy process (infinite `lists:seq(1,1024)`
loop). Actual output:

```
quiet:  statistics(reductions) delta = 24002 ; process_info(self(),reductions) delta = 27374
noisy:  statistics(reductions) delta = 52000 ; process_info(self(),reductions) delta = 27339 ; busy ack = ok
contamination: noisy-global >= 1.5x quiet-global: true ; local flat (<=1.2x+100): true
VERDICT-2: concurrent work contaminates statistics(reductions) reds_per_op deltas
```

Interpretation: the node-global delta came out **2.17x** the quiet baseline while the
caller-local delta stayed flat (27339 vs 27374). Under AR-BENCH-01 as written
(`statistics(reductions)` delta with the body "executed in the measuring process"), any
concurrent lane on the same node inflates `reds_per_op` by an unbounded factor — the
attribution claim "the delta attributes to the body" is false. This also means
AR-BENCH-01's fence is unsound in exactly the regime bench lanes exist for: concurrent
load.

## Probe 3 — corrected primitive is available (`/tmp/bench10_probe3.escript`, exit 0)

```
otp_release = 28
worker reductions: before=0 after=794206 delta=794206 (worker did 3000 x lists:seq(1,1024))
process_info(foreign pid, reductions) readable from the caller after completion: 0 (worker exited)
```

`process_info(Pid, reductions)` works on a foreign pid, counts only that process's work
(794206 reductions for its own 3000 `lists:seq(1,1024)` calls while the caller ran its own
concurrent batch), and the caller's concurrent work does not leak into it. Per-process
reductions accounting is available since OTP 18.0 (release notes; verified live on the
OTP 28 runtime here). This makes the fix direction concrete and cheap:

**Corrected pattern** (for both INVALID fences): run the measured body N times in an
**isolated worker process**; bracket the batch with `process_info(Worker, reductions)`
deltas and a final `process_info(Worker, heap_size)` after double-GC; wall-clock stays
`monotonic_time` in the caller. This bounds both fences to the measured process by
construction and is concurrency-proof.

## Falsifiers for this receipt

- Probe 1 exit 1 (`FAILED to reproduce`) would refute the node-global claim for the
  heap gate; it exited 0.
- Probe 2 exit 1 would refute reduction contamination; it exited 0 (2.17x).
- Probe 3 exit 1 would refute per-process reductions availability; it exited 0.

## Honest disclosures

- All probe drafts required fixes before landing (probe 1: baseline taken after the
  allocation signal; probe 3: sync bug, then unsafe-variable compile error). Only the
  final exits above are evidence; the failed drafts exited 1/127.
- Local runtime is OTP 28, not the OTP-29 window the spec targets — per-process
  `process_info(Pid, reductions)` is documented since OTP 18.0 so the availability
  verdict transports, but the OTP-29 toolchain should re-run the three escripts as a
  formality on re-land.
- Machine context: single-node loopback, no bench-machine recipe invoked (pure-Erlang
  probes; `just bench-machine` output not applicable to this audit lane — no load or
  throughput numbers emitted here, probes only).
