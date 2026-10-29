# Receipt — S1 actor fan-out engine (PopcornDemo.Concurrency)

- Date: 2026-10-20
- Lane: S1 (writer, SCVD harness core)
- Subject: `/Users/sac/smalt/popcorn_demo/lib/popcorn_demo/concurrency.ex` (new)
- Build root: `popcorn_demo/_build-s1` (lane lease; coordinator reclaims)

## Standing: ALIVE (host-side; cook not run — coordinator's)

## Module

`PopcornDemo.Concurrency` — pure in-memory actor fan-out engine for the wasm
BEAM slice:

- `ramp/1`: spawns N isolated processes; each actor runs a deterministic
  in-memory verification walk over the three shipped smalt modules
  (`Smalt.CosmosSql.run/3` on a zero-lock, per-actor-keyed doc set
  `actor-<id>-doc-<i>` / partition `p<id>`; `Smalt.SbRules` compile + record
  `subscription_admits?/2` hit/miss + `apply_action/2`; `Smalt.Registry`
  admitted?/admitted_version?/latest_version pins). Three states, fail-closed:
  `:verified` (every step byte-exact), `:environment_skip` (subject modules
  not loadable — counted apart, never as verified), `:invariance_breach`
  (any non-byte-exact step; first offender in `breach_detail`).
  Ramp row `%{n, wall_ms, p50_us, p99_us, verified, breaches,
  reductions_total}` (see the module doc for the exact contract).
- `contention/1`: N actors race 8 contended ETS keys via optimistic CAS
  (atomic `insert_new` claim -> match exists-check -> conditional update to
  `:committed`). Asserts deterministic final state; deviation returns
  `{:error, {:not_deterministic, detail}}`.

Zero-egress by construction: no sockets, no `:httpc`, no `Popcorn.Fetch`.
Bounded loops only (single atomic CAS decision per actor-key; no spin).

## Real host output (pinned toolchain OTP 29.0.6 / Elixir 1.20.4-otp-29)

Command: `MIX_BUILD_ROOT=_build-s1 mix compile --warnings-as-errors` —
0 warnings from concurrency.ex (grep count 0; other pre-existing
`Transport.Fetch`/`:public_key` warnings in the demo are out of lane scope).

Post-audit gate legs (S6 fixes F1-F3 applied; the gate legs below are the
standing numbers):

```
RAMP16 %{n: 16, wall_ms: 9.811, p50_us: 9725, p99_us: 9759, verified: 16, breaches: 0, reductions_total: 52376}
CONTENTION64 {:ok, %{keys: 8, n: 64, winners: 8, losers: 56, committed_rows: 8}}
RAMP8 %{n: 8, wall_ms: 0.346, p50_us: 49, p99_us: 79, verified: 8, breaches: 0, reductions_total: 23792}
RAMP64 %{n: 64, wall_ms: 0.743, p50_us: 45, p99_us: 107, verified: 64, breaches: 0, reductions_total: 190831}
```

`WALK3`: `state: :verified, breach_detail: nil, wall_us: 68,
reductions_before: 359418, reductions_after: 362391`.

Pre-audit legs (earlier in session, superseded by the gate legs above):
`CONTENTION32 {:ok, %{keys: 8, n: 32, committed_rows: 8, losers: 24,
winners: 8}}`, `RAMP8 ... p50_us: 8771 ... wall_ms: 8.794`, `RAMP64 ...
p50_us: 11099 ... wall_ms: 11.753`.

## Session fix log (all in-lane)

0. **S6 audit F1-F3 (all three verified by execution, addressed)**:
   - F1 (HIGH): cosmos params `%{"@pk" => ...}` -> `%{"pk" => ...}` — the
     engine keys params WITHOUT the `@`; `@pk` made `:verified` unreachable
     (every actor returned Unbound-parameter syntax errors).
   - F2 (HIGH): `ramp/1` receive had no `after` and actors were unmonitored —
     one crashed actor hung the parent forever (exercised live at S6:
     ramp(16) hung 120s to SIGTERM). Fixed with `spawn_monitor` per actor;
     a `{:DOWN, ref, :process, pid, reason}` is classified as a typed
     invariance breach (`{:actor_crashed, reason}`) via `crashed_report/2`,
     counted in `breaches`, never silent, never a hang. Monitor demons are
     demonitor'd `[:flush]` on the happy path (an initial `[:purge]` option
     was itself an ArgumentError and was caught + fixed by the rerun).
   - F3 (HIGH): `assert_contention_final/2` called `length/1` on the
     `collect/2` MAP -> ArgumentError, determinism verdict unreachable.
     Fixed with `map_size/1` + `Map.values/1` partition counts.
1. `%{"@pk" => ...}` param key -> `%{"pk" => ...}` (CosmosSql params are keyed
   without the `@`) [same fix as F1, found independently in-lane]
2. `subscription_admits?/2` takes stored rule RECORDS (`%{"properties" => ...}`)
   — wrap the filter via `Smalt.SbRules.build_rule_record/3`
3. `sys.label` reads top-level `:label`; `subject` resolves against
   `:app_props` — message shape aligned to the rule engine's actual lookup
   (this was the last breach; without it the walk correctly BREACHED rather
   than coerced — fail-closed behavior witnessed live)
4. `length/1` on a results MAP in `assert_contention_final/2` -> `map_size/1`

## Fail-closed witness (real, not narrative)

Before the message-shape fix, every actor returned
`{:invariance_breach, {:sb_rules_match, id, false, false}}` and
`ramp(8)` reported `breaches: 8, verified: 0` — the walk breached loudly on
a harness defect rather than coercing a pass. Failure mode itself exercised.

## Honest notes

- The pre-fix RAMP64 (breaches: 64) was a real fail-closed witness, not a
  clean leg; the post-fix RAMP64 above (verified: 64, breaches: 0) is the
  standing number. No bench jsonl emitted (this lane is a harness module,
  not a bench lane).
- Not wired into supervision tree; no test file authored (task scope:
  harness core, compile + host smoke only). Cook deliberately not run.