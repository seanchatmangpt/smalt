# Phase-1 Capability Probes — T37P1 (ARD-PRD v26.10.21)

Context: solo
**Standing:** PARTIAL_ALIVE

**Lane**: T37P1 (bench-runner) · **Date**: 2026-10-21 · **Standing: PARTIAL_ALIVE**
**Context: solo**
**Probe**: `tmp/otp29_probes/t37p1_phase1.escript`
(`escript t37p1_phase1.escript all|iterator|prio_alias|trace_session`)

Prior art: `docs/jira/v26.10.20/receipts/otp29-capability-probes.md` was NOT
landed at probe start; it landed mid-run. This lane proceeded independently
(no file duplication — that receipt covers trace-drop/binbench/eep79/
maporder/ssl/guard). **Delta check on OTP 29.1.1** (that receipt's OTP-29
leg; mine used the popcorn pin 29.0.6): all three verdicts IDENTICAL —
`process_next/1` still absent, priority alias still zero head injection
(`normals_before_prio => 50000`), trace-session cross-drop still zero.
Overlapping
in-flight probes (`tmp/otp29_probes/p1_trace.escript` et al.) cover other
claims (self-trace, binbench, eep79, maporder, ssl, guard); no file duplication.

## Verdict table

| Claim | API | OTP 28.3 / erts 16.2 | OTP 29.0.6 / erts 17.0.6 | Verdict |
|---|---|---|---|---|
| P1a processes iterator | `erlang:processes_iterator/0` | runtime=true | runtime=true | AVAILABLE on BOTH |
| P1b iterator next | `erlang:process_next/1` (ARD name) | runtime=**false** | runtime=**false** | **REFUTED** (name) |
| P1c iterator next | `erlang:processes_next/1` (actual) | runtime=true | runtime=true | AVAILABLE on BOTH |
| P2 EEP-76 priority alias | `erlang:alias([priority])` head injection | option accepted, **0 head injection** | option accepted, **0 head injection** | **REFUTED (behavioral gate)** on BOTH |
| P3 isolated trace sessions | `trace:session_create/3` | AVAILABLE (OTP 27+ API, not OTP-29-specific) | AVAILABLE, zero cross-drop | AVAILABLE on BOTH |

## Measured gates

### P1 — iterator heap gate (200k dummy processes spawned)

Iterator (`processes_iterator/0` + `processes_next/1`), OTP 28.3
(iter_ms 16, heap delta **2353 words**) and OTP 29.0.6 (iter_ms 13,
heap delta **2353 words**):

```
gate (iterator over 200043 total procs): #{n_visited => 200043,iter_ms => 13,
                                           heap_before_words => 233,
                                           heap_after_words => 2586,
                                           heap_delta_words => 2353}
baseline (processes/0): #{n_visited => 400043,heap_before_words => 376,
                          heap_after_words => 833026,
                          heap_delta_words => 832650,list_ms => 13}
```

Iterator peak-caller-heap delta is 2353 words vs **832,650 words** for
`processes/0` over the same 200k+ process population — the O(1)-memory
sweep claim HOLDS (delta is the iterator's chunk buffer, not an O(N) list;
~354x reduction). Identical delta on both toolchains.

### P2 — priority alias drain gate (50k queued normals)

```
gate (50k queued normals): #{normals_before_prio => 50000,
                             prio_latency_us => 387}   % OTP 29.0.6
gate (50k queued normals): #{normals_before_prio => 50000,
                             prio_latency_us => 14}    % OTP 28.3
```

`erlang:alias([priority])` returns an alias on BOTH toolchains (no badarg),
but the priority message is delivered **after all 50,000 queued normals**
(`normals_before_prio = 50000`, ARD gate requires 0). EEP-76 priority
signaling is NOT functionally present in OTP 29.0.6 as shipped. Phase-1's
"priority aliases across core supervisor loops" item must be re-scoped
(typed REFUTED, do not implement against this API).

### P3 — isolated multi-session trace gate (2 sessions, same MFA)

```
enable returns: p1=1 p2=1 f1=1 f2=1
disable returns: 1 1
gate HOLDS (2 sessions, same MFA {lists,seq,2}, zero cross-drop): #{s2_r2_after_s1_stop => 3,
                                                                    s1_r1 => 2}
```

Two concurrent sessions traced `{lists,seq,2}` on one worker via per-session
tracer processes; both delivered in round 1 (s1=2, s2=2 control); after
stopping ONLY session 1 (flags off + pattern off), session 2 continued
delivering (3 events in round 2) — zero cross-drop HOLDS on both toolchains.
Note: the ARD pins this as OTP-29-specific; it is actually an **OTP 27.0**
API (`kernel-11.0.3/src/trace.erl`, `-doc #{ since => <<"OTP 27.0">> }`) and
runs on OTP 28.3 as-is.

## Method notes (honest-numbers section)

- Availability verdict is **runtime-based** (`erlang:function_exported/3`
  AFTER `code:ensure_loaded/1`); the eval-based compile attempt is recorded
  but informational only — `erl_eval` rejects some BIFs that exist and run
  from compiled code (`processes_next/1`: runtime=true, eval=no).
- Two probe bugs were found and fixed during the run (both in probe
  scaffolding, not the substrate): (a) `function_exported` false-negatives
  for unloaded modules (`trace`), (b) a counter loop that exited after its
  first tally, which masqueraded as "session 2 events lost". The corrected
  gate shows cross-drop is zero.
- Probe runs shared the machine with the concurrent in-flight otp29 probes
  lane (p4_maporder / p8_arcore02_drain escripts were live); timings are
  load-bound, the heap-word deltas and event counts are not.
- `prio_latency_us` for P2 is the residual tail latency after the sender
  finished enqueueing, not the queue-jump time; the gate's verdict variable
  is `normals_before_prio`, which is load-independent.

## Re-scope consequences for the ARD

1. `process_next/1` → rename to `processes_next/1` in Phase-1 text
   (returns `{Pid, It2}` chunked iterator; `none` at end).
2. EEP-76 `alias([priority])` → typed REFUTED on OTP 28.3 and 29.0.6
   (option accepted, behavior absent). Drop from Phase-1 scope or re-pin to
   a future OTP that actually ships priority delivery.
3. `trace:session_create/3` → AVAILABLE now (OTP 27+); Phase-4's isolated
   trace-session migration is unblocked on the current toolchain, and its
   "OTP 29" premise can be corrected to OTP 27+.

## Machine

```
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

(`just bench-machine`)
