# FONDRUNNER — HTN→FOND→POWL→OCEL gen_statem pipeline (parallel Erlang family, OTP 29)

**Standing:** **ALIVE** (7/7 courts green, 3 consecutive runs byte-stable)
Date: 2026-10-21 · Lane: FONDRUNNER (writer, OTP-29) · Repo: /Users/sac/smalt
Context: solo

## Subject

New parallel Erlang module family — the landed Elixir `Smalt.POWL2`/`PPlan` stack untouched:

- `lib/smalt/pipeline/smalt_fond_plan.erl` — plan algebra: linear HTN decomposition, Kahn
  acyclicity assert (crash-only `{cyclic_plan, Remaining}`), needs/provides readiness.
- `lib/smalt/pipeline/smalt_fond_seal.erl` — deterministic Merkle seal behind the IMPL-12
  order-fingerprint gate: `otp_release >= 28` AND `phash2(maps:keys(64-key sentinel)) == 628801`
  (29.1.2-pinned constant), else typed
  `{refuse, {order_fingerprint_mismatch, Got, Want}}` — no digest minted.
  Gate not vacuous: real binaries give 26.2.1 → 39096764, 28.3 → 11734956 (both refuse).
- `lib/smalt/pipeline/`lib/smalt/pipeline/smalt_fond_powl_runner.erl` — gen_statem, `callback_mode() ->
  [state_enter, handle_event_function]`, 5 stages htn → fond → powl → ocel → seal.
- Courts: `test/pipeline/fond_powl_runner_court_test.exs` (7 tests).
- Build: `MIX_BUILD_ROOT=_build-fondrun`, pinned toolchain
  `~/.asdf/installs/erlang/29.1.2` + Elixir 1.20.4-otp-29 (explicit PATH pin; PATH-default erl is 28.3.1 and mix refuses Elixir 1.19.5).

## Spec corrections applied (as ordered)

1. **Seal determinism — gate form (operator-sanctioned)**: raw `maps:fold` streaming behind
   IMPL-12's gate (otp_release ≥ 28 + sentinel fingerprint 628801 + typed
   `{order_fingerprint_mismatch, Got, Want}` refusal). NOT sorted-key hashing; NOT bare fold.
2. **Retry ceiling wired through `is_integer/3`**: `loopback/2` guarded clause
   `when is_integer(R, 0, Max)` admits retries ∈ [0, Max]; fallthrough is the crash-only
   exhaustion path `erlang:error({fond_loop_bound_exhausted, #{retries => 11, ...}})`.

## gen_statem state_enter law (load-bearing finding)

An `enter` call may NOT change state (bad_state_enter_return, gen_statem.erl ~3774) and may
NOT insert events (bad_state_enter_action / StateCall-gated branches, ~3990). The lawful
self-driving form: `init` and event handlers (StateCall context) mint
`{next_event, internal, advance}` alongside the transition; the `enter` call of each state
fires (state_enter mode) as the entry hook and re-fires on the fond 412 loopback
(same-state re-entry). First attempt with next_event-from-enter crashed
`bad_state_enter_action_from_state_function` — witnessed, corrected in-tree.

## What ran (receipt-grade output)

```
$ MIX_BUILD_ROOT=_build-fondrun mix test test/pipeline/fond_powl_runner_court_test.exs
Result: 7 passed            # x3 consecutive runs, 0.07–0.09s, zero flakes
```

Courts:
- (a) happy path: `{ok, Receipt}` — merkle 32 bytes (`<<_::256>>`), event_count = 3 steps +
  3 htn_decompose + 3 pipeline (powl_projected/ocel_finalized/sealed) = 9, otp_release 29.
- (b) forced 412: 11 loopbacks (ledger shows 11 fond_412_loopback events, retries=11 vs
  max_retries=10) → `{crash, {{:fond_loop_bound_exhausted, info}, _stk}}` at `loopback/2`.
  Flaky variant (each step 412s exactly twice, Agent-owned counter — real collaborator):
  completes, event_count = 6 + 3 + 3 + 3 = 15.
- (c) determinism: 3 full pipeline runs byte-identical merkle; identical fixed ledger sealed
  from two fresh processes → identical 32-byte digests.
- (d) cyclic plan → `{crash, {{:cyclic_plan, [:a, :b]}, _stk}}` at the Kahn assert.
- Gate: admits on 29.1.2 (fp 628801); negative fixture executed against real 26.2.1 and 28.3
  binaries via `erl -noshell -eval` (26.2.1 → 39096764, 28.3 → 11734956 — both ≠ 628801 ⇒ refuse).

## Defect found and fixed in-session (two-sender exit race)

First `run/1` relayed the receipt with a raw `Parent ! {pipeline_complete, R}` from the FSM
plus a `monitor`/'DOWN' fallback. Real-SDK discipline found it nondeterministic: the receipt
send and the kernel 'DOWN' come from two unordered senders, so DOWN(normal) can overtake the
receipt — witnessed `{crash, :normal}` and `{crash, :noproc}` on repeated runs. Fix: the FSM
carries the receipt out as its exit reason `{stop, {completed, Receipt}}`; `run/1` waits on
exactly one 'DOWN' and pattern-matches the receipt — single sender, no race. 6-run loop repro
(green/green/green/crash-normal/…/noproc before; 6/6 green after).

## Shared-tree disclosures (compile-freeze SLA)

No other lane's file was edited. Two freezes were waited out with bounded polls (≤3 polls,
~90s): `lib/smalt/json_compat.ex` (undefined run_stream/5) and
`lib/smalt/data_plane/key_vault_actions.ex` (misplaced ^bits — since fixed by owner).
`mix.exs` carried a pre-session in-flight edit (`elixir: "~> 1.20"` pin, not mine); my only
mix.exs delta is `erlc_paths: ["lib/smalt/pipeline"]` so Mix's :erlc compiler picks up the
family (default erlc_paths is ["src"], unused here).

## Falsifiers

- Courts fail if: seal stops being deterministic (fingerprint gate should refuse first);
  the retry guard admits R > Max; a cyclic plan boots; the receipt's merkle is not 32 bytes.
- Gate falsifier: any OTP release that changes 64-key map order while otp_release ≥ 28 and
  fp happens to equal 628801 — measured impossible-by-construction today (26.2.1/28.3 differ).

## Receipt fields

- Exact subject: smalt HEAD + the five files above, OTP 29.1.2, Elixir 1.20.4-otp-29,
  MIX_BUILD_ROOT=_build-fondrun.
- Commands: `MIX_BUILD_ROOT=_build-fondrun mix compile` (exit 0);
  `MIX_BUILD_ROOT=_build-fondrun mix test test/pipeline/fond_powl_runner_court_test.exs`
  (exit 0, 7 passed, x3); cross-release erl fingerprint evals (exit 0).
- Consequence: the operator's HTN→FOND→POWL→OCEL pipeline exists as a parallel Erlang
  module family compiled in-repo; the IMPL-12 gate form is exercised as landed code.
- Replay: checkout, `MIX_BUILD_ROOT=_build-fondrun mix compile`, then the test command above.
- **Standing:** ALIVE (courts green x3, deterministic seal witnessed, crash paths typed).
