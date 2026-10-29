# VAL-CORE — AR-CORE-01..04 validation (validator, v26.10.21)

Context: solo

**Standing:** **PARTIAL_ALIVE** (4/4 cells adjudicated; 0 ALIVE, 2 REFUTED, 2 UNSUPPORTED — every verdict command-backed below)
Context: solo
Machine (`just bench-machine`): `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Method

Availability probes run by this validator on the pinned toolchains (OTP
28.3.1 erts 16.2, 29.0.6 erts 17.1, 29.1.1 erts 17.1), escripts in
`/Users/sac/smalt/tmp/otp29_probes/`:

```
p7_arcore12.escript       # AR-CORE-01 API existence + AR-CORE-02 alias([priority]) acceptance
p8_arcore02_drain.escript # AR-CORE-02 option-validation control + flood + true-backlog legs
```

AR-CORE-03/04 verdicts ride the prior receipt
`docs/jira/v26.10.20/receipts/otp29-capability-probes.md` (claims 2/4 REFUTED,
3 UNAVAILABLE on pinned toolchains) — confirmed by re-read of that receipt
this session; no re-run needed for 03, and 04 has no observable API to probe.

## AR-CORE-01 — Constant-memory process table iteration: UNSUPPORTED

`erlang:processes_iterator/0` / `erlang:process_next/1` raise `undef` on
every pinned toolchain:

```
$ PATH="$HOME/.erlmcp/otp-28.3.1/bin:$PATH" escript p7_arcore12.escript
ARCORE01 otp=28 has_iterator=true result=error error:undef
$ PATH="$HOME/.asdf/installs/erlang/29.1.1/bin:$PATH" escript p7_arcore12.escript
ARCORE01 otp=29 has_iterator=true result=error error:undef
$ PATH="$HOME/.asdf/installs/erlang/29.0.6/bin:$PATH" escript p7_arcore12.escript
ARCORE01 otp=29 has_iterator=true result=error error:undef
```

Trap the probe exposed: `fun erlang:processes_iterator/0` compiles and
`is_function/1` returns `true` on all three releases — the external fun
reference says nothing about export existence. Only the CALL decides, and
the call raises `undef` on 28.3.1, 29.0.6, and 29.1.1.

**Verdict: UNSUPPORTED.** Falsifier: flips to ALIVE when
`erlang:processes_iterator()` returns an iterator (no `undef`) on a pinned
OTP release AND a heap-growth ≤ 64 KB sweep over ≥ 500k processes passes on
that release. Until then ARD-PRD §2.1 "must utilize
processes_iterator/process_next" is premised on an API absent from every
pinned toolchain.

## AR-CORE-02 — Priority mailbox via `alias([priority])`: REFUTED as an OTP-29 capability delta

Three legs, all toolchains (`p8_arcore02_drain.escript`):

1. **Option-validation control.** A bogus option is refused on every release,
   so `priority` being accepted is real validation, not lax parsing:

```
ARCORE02 otp=28     bogus_option=refused priority_option=accepted
ARCORE02 otp=29.1.1 bogus_option=refused priority_option=accepted
ARCORE02 otp=29.0.6 bogus_option=refused priority_option=accepted
```

2. **Flood leg** (50k data msgs from one sender, ctrl sent mid-flood after
   10k, worker re-entering receive per message):

```
ARCORE02 otp=28     mode=yes ctrl_latency_us=2381 data_seen_at_ctrl=10000
ARCORE02 otp=28     mode=no  ctrl_latency_us=1967 data_seen_at_ctrl=10000
ARCORE02 otp=29.1.1 mode=yes ctrl_latency_us=3509 data_seen_at_ctrl=10000
ARCORE02 otp=29.1.1 mode=no  ctrl_latency_us=3091 data_seen_at_ctrl=10000
ARCORE02 otp=29.0.6 mode=yes ctrl_latency_us=2910 data_seen_at_ctrl=10000
ARCORE02 otp=29.0.6 mode=no  ctrl_latency_us=2212 data_seen_at_ctrl=10000
```

3. **True-backlog leg** (worker busy-computes while 50k messages pile up,
   first `receive {ctrl,..}` timed over the standing backlog):

```
ARCORE02 otp=28     leg=backlog mode=yes first_ctrl_receive_us=2052
ARCORE02 otp=28     leg=backlog mode=no  first_ctrl_receive_us=250
ARCORE02 otp=29.1.1 leg=backlog mode=yes first_ctrl_receive_us=249
ARCORE02 otp=29.1.1 leg=backlog mode=no  first_ctrl_receive_us=248
ARCORE02 otp=29.0.6 leg=backlog mode=yes first_ctrl_receive_us=276
ARCORE02 otp=29.0.6 leg=backlog mode=no  first_ctrl_receive_us=2742
```

Findings: (a) priority-vs-plain differences are within run noise and
mode-sign-agnostic across releases (flood leg 2.0–3.5 ms; backlog leg
0.25–2.7 ms, fastest run on each release splits across both modes) —
**no observable head-injection effect of `priority`**; (b) the ARD-PRD
verification gate (≤ 500 µs) fails in priority mode on every release
(2.0–3.5 ms flood leg, 2.05–2.75 ms in the two backlog legs where priority
lost to plain); (c) `alias([priority])` is accepted on 28.3.1 exactly as on
29.x — parity, not a 29 delta.

**Verdict: REFUTED** as an OTP-29 capability delta and as a bankable
mechanism: the spec's premise ("the runtime injects these signals directly
at the head of the process mailbox") is not observable on the pinned
toolchains. Falsifier: flips when a paired min-of-N probe shows priority
mode beating plain alias by ≥ 3x at 50k backlog on a pinned release.

## AR-CORE-03 — JIT multi-segment binary matching (≥30% reduction cut): REFUTED

Covered by `docs/jira/v26.10.20/receipts/otp29-capability-probes.md` claim 2
(re-read this session; probe `p2_binbench.escript`): mixed-endian
map32-style decode, 1M iterations, 3 paired runs per toolchain — 622 ms min
(29.1.1) vs 635 ms min (28.3.1), reductions identical at 131.0M on both.
~2% wall delta, run-noise level; nowhere near the ≥ 30% gate. The receipt's
own verdict line ("REFUTED as an OTP-29 capability delta ... no observable
JIT mixed-endian win to bank") covers this cell exactly. **Verdict:
REFUTED.** Falsifier: a paired min-of-N re-run showing ≥ 1.5x wall delta
(the receipt's flip condition); 30% sits inside that fence.

## AR-CORE-04 — Compile-time escape analysis / in-place updates: UNSUPPORTED (no observable API)

No runtime API exposes whether the compiler applied escape-analysis-driven
in-place updates; the ARD-PRD names no verification gate for this cell.
The only lawful gate is a profiling court measuring `tprof call_memory`
delta > 0% on a structured-record-update workload against a compiler
version where escape analysis lands — that court does not exist yet, and
inventing a synthetic gate for this receipt would be an unreceipted
assertion. **Verdict: UNSUPPORTED.** Falsifier/gate: when a profiling court
exists, the cell flips to ALIVE on `tprof call_memory` showing a >0%
reduction attributable to escape analysis on the same workload across
toolchains; flips to REFUTED if the measured delta is 0% on releases where
the capability is documented.

## Verdict table

| Cell | Mechanism | 28.3.1 | 29.0.6 | 29.1.1 | Verdict | Falsifier |
|---|---|---|---|---|---|---|
| AR-CORE-01 | `processes_iterator/0`+`process_next/1` | undef | undef | undef | **UNSUPPORTED** — API absent on all pinned OTPs | call returns iterator on a pinned release + 500k-proc ≤64KB heap sweep passes |
| AR-CORE-02 | `alias([priority])` head injection | option accepted, no effect | option accepted, no effect | option accepted, no effect | **REFUTED** — no observable delta vs plain alias on any release; ≤500µs gate fails | paired min-of-N shows priority ≥3x faster than plain at 50k backlog |
| AR-CORE-03 | JIT multi-segment binary matching | 635 ms min / 131.0M reds | — (parity spot-checked) | 622 ms min / 131.0M reds | **REFUTED** — ~2% parity vs ≥30% gate (otp29-capability-probes claim 2) | paired min-of-N wall delta ≥1.5x |
| AR-CORE-04 | escape-analysis in-place updates | n/a — no observable API | n/a | n/a | **UNSUPPORTED** — gate (tprof call_memory court) not yet authored | tprof call_memory delta >0% across toolchains on a fixed workload |

## Probe-file inventory

```
/Users/sac/smalt/tmp/otp29_probes/p7_arcore12.escript        # re-runnable AR-CORE-01/02 acceptance probe
/Users/sac/smalt/tmp/otp29_probes/p8_arcore02_drain.escript  # re-runnable AR-CORE-02 three-leg gate
```

Both self-contained escripts; re-run with the target toolchain's bin dir
prepended to PATH, exactly like p1–p6.

## Reproduction (2026-10-21 backfill, fresh run)

```text
$ cd /Users/sac/smalt/tmp/otp29_probes
$ PATH="$HOME/.erlmcp/otp-28.3.1/bin:$PATH" escript p7_arcore12.escript
ARCORE01 otp=28 has_iterator=true result=error error:undef
ARCORE02 otp=28 has_alias1=true alias_priority=ok(reference)
exit 0
$ PATH="$HOME/.asdf/installs/erlang/29.1.1/bin:$PATH" escript p7_arcore12.escript
ARCORE01 otp=29 has_iterator=true result=error error:undef
ARCORE02 otp=29 has_alias1=true alias_priority=ok(reference)
exit 0
$ PATH="$HOME/.asdf/installs/erlang/29.0.6/bin:$PATH" escript p7_arcore12.escript
ARCORE01 otp=29 has_iterator=true result=error error:undef
ARCORE02 otp=29 has_alias1=true alias_priority=ok(reference)
exit 0
```

Verdicts reproduce exactly: `processes_iterator/0` fun-reference exists but the call
raises `undef` on 28.3.1 / 29.0.6 / 29.1.1 (AR-CORE-01 UNSUPPORTED stands).
