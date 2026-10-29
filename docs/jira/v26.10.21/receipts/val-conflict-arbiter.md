# VAL Conflict Arbiter — AR-CORE-01 / AR-OBS-01 (v26.10.21)

Context: solo

**Standing:** **PASS** (arbiter court executed on all three pinned toolchains; both
conflicting cells decided by direct reproduction of BOTH receipts' probes plus a
tie-break escript that isolates the mechanism).

- Date: 2026-10-21
- Repo: /Users/sac/smalt @ dfe49a00181c6ed6734d95d7bb8e2061118b9f2a
- Tie-break escript: `/Users/sac/smalt/tmp/otp29_probes/arbiter_iter_trace.escript`
  (re-runnable: `escript arbiter_iter_trace.escript all`)
- Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}` (`just bench-machine`)

## Method

1. Re-ran VAL-CORE's `p7_arcore12.escript` (ARCORE01 lines) and VAL-OBS's
   `obs_probes.escript` (OBS01 lines) verbatim on the same PATHs the receipts name:
   `~/.erlmcp/otp-28.3.1/bin`, `~/.asdf/installs/erlang/29.0.6/bin`,
   `~/.asdf/installs/erlang/29.1.1/bin`. Printed `otp/erts` verified per leg
   (28/16.2, 29/17.0.6, 29/17.1).
2. Re-ran T37's `t37p1_phase1.escript trace_session` on the same legs.
3. Ran the tie-break escript isolating: (a) module loading state, (b) the exact
   opts form each side passes, (c) the exact next-function name each side calls.

## Cell 1 — `erlang:processes_iterator/0` (+ next)

**Final verdict: AVAILABLE (overrides val-ar-core.md AR-CORE-01 UNSUPPORTED).**
T37's (phase1-capability-probes.md) AVAILABLE stands.

Mechanism (root cause of the false undef): **VAL-CORE's probe bug, not release
skew, not escript-vs-mix environment.** The real API is
`processes_iterator/0` + **`processes_next/1`**. p7's `walk/3` calls the
ARD-named **`process_next/1`** — an export that does not exist on any of the
three releases — so the walk raises `undef`, which the probe's `try` misattributes
to `processes_iterator/0` ("the call raises undef"). `processes_iterator()`
itself succeeds everywhere.

Deciding output (28.3.1; 29.0.6 and 29.1.1 identical modulo pid set):

```
== ITER otp=28 erts=16.2 ==
function_exported(erlang,processes_iterator,0)=true
function_exported(erlang,processes_next,1)=true
function_exporterlang(process_next,1)=false
raw processes_iterator() => {0,[]}
raw processes_next(it) => {<0.0.0>,{99775,[<0.1.0>,<0.2.0>,...
erlang iterator-ish exports: [{processes_next,1},{processes_iterator,0},{processes,0}]
```

Mechanism proof — the exact undef p7 caught, called directly:

```
$ erl -noshell -eval 'io:format("~p~n",[catch erlang:process_next(ignored)]),halt().'
{'EXIT',{undef,[{erlang,process_next,[ignored],[]}, ...
```

Same result on 29.0.6 (erts 17.0.6, kernel-11.0.3 trace.beam path verified) and
29.1.1 (erts 17.1, kernel-11.0.4). Both receipts ran on the same release binaries
per PATH leg (code:which(trace) resolved inside each install), so module-loading
order is NOT the mechanism for this cell; the wrong export name is.

Scope note kept from VAL-CORE: the ARD falsifier's full gate (≤64KB heap over
≥500k processes) remains unmet — T37's measured gate is 200k procs, 2353 words
(~18.8 KB). So the corrected cell is typed AVAILABLE (API exists and walks) with
the 500k gate still open, not ALIVE. The prior receipt's sub-claim that
`fun erlang:processes_iterator/0` compiling with `is_function/1` true "says
nothing about export existence" is also corrected: `function_exported(erlang,
processes_iterator, 0)` is genuinely `true` here because the `erlang` module is
always loaded — that check was valid, and it agrees with T37's.

## Cell 2 — `trace:session_create/3`

**Final verdict: AVAILABLE (overrides val-ar-obs.md AR-OBS-01 UNSUPPORTED).**
T37's AVAILABLE stands, on both legs.

Mechanism: two independent probe defects in `obs_probes.escript`, both
reproduced. (a) **No `code:ensure_loaded(trace)`** — `function_exported/3` sees
only loaded modules, so it prints false even though `trace.beam` ships in kernel
(kernel-10.5 on 28.3.1, kernel-11.0.3 on 29.0.6, kernel-11.0.4 on 29.1.1 — the
API is OTP 27+, not release skew). (b) **Opts passed as `#{}` (map), not a
list** — `trace:session_create(Name, Tracer, Opts)` validates Opts as a list and
raises badarg at trace.erl line 1510. T37 passes `[]` and the two-session
zero-cross-drop gate holds (s1_r1=2, s2_r2_after_s1_stop=3) on every leg.

Deciding output (tie-break, verbatim; 29.1.1 shown, 28.3.1/29.0.6 same shape):

```
== TRACE otp=29 erts=17.1 ==
function_exported(trace,session_create,3) BEFORE ensure_loaded=false
code:which(trace)="/Users/sac/.asdf/installs/erlang/29.1.1/lib/kernel-11.0.4/ebin/trace.beam"
function_exported AFTER ensure_loaded=true
session_create(name, self(), #{})  [VAL-OBS opts form] => {'EXIT',{badarg,
    [{trace,session_create,[arb_map_opts,<0.10.0>,#{}],
      [{file,"trace.erl"},{line,1510},{error_info,#{module => erl_kernel_errors}}]}, ...
session_create(name, self(), [])   [T37 opts form]      => {#Ref<0.1713219461.612499460.19972>,{arb_list_opts,0}}
```

Re-runs of the receipts' own probes (all three legs):

```
$ PATH=...otp-28.3.1/bin:$PATH escript p7_arcore12.escript
ARCORE01 otp=28 has_iterator=true result=error error:undef          <- probe bug, see above
$ PATH=...29.1.1/bin:$PATH escript t37p1_phase1.escript trace_session
  gate HOLDS (2 sessions, same MFA {lists,seq,2}, zero cross-drop): #{s2_r2_after_s1_stop => 3, s1_r1 => 2}
  => {"trace_session","AVAILABLE"}
$ PATH=...29.1.1/bin:$PATH escript .../val_ar_obs/obs_probes.escript
OBS01 session_create_exported=false
OBS01 session_create_error=error:badarg                              <- probe defects, see above
```

## Arbiter table

| Cell | Mechanism found | Losing receipt | Corrected verdict | Residual gate |
|---|---|---|---|---|
| AR-CORE-01 `processes_iterator/0` | probe called nonexistent `process_next/1` in walk → undef misattributed | val-ar-core.md (AR-CORE-01) | **AVAILABLE** — overrides UNSUPPORTED | 500k-proc ≤64KB sweep unmet (measured 200k/2353 words); re-pin to `processes_next/1` |
| AR-OBS-01 `trace:session_create/3` | missing `code:ensure_loaded(trace)` + opts `#{}` instead of `[]` | val-ar-obs.md (AR-OBS-01) | **AVAILABLE** — overrides UNSUPPORTED | Phase-4 isolated-trace-session migration unblocked; API is OTP 27+, correct the "OTP 29" premise |

The other lanes' receipts are intentionally NOT edited — the overrides above are
typed here only; owners should re-type their cells from this receipt.

## Falsifier

This receipt flips to SUSPECT if any pinned toolchain re-run of
`arbiter_iter_trace.escript all` shows `raw processes_iterator() => undef` or
`session_create(name, self(), [])` raising, on a verified `otp/erts` banner.
