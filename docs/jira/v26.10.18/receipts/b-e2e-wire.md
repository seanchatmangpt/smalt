# b-e2e-wire — E2E/WIRE consolidation slice (v26.10.18)

Standing: ALIVE (all validation gates green on the touched surfaces)
Context: slice of v26.10.18 rewrite batch (e2e-wire draft D1/D4; D2/D3 out of
this slice's lease; s6/s9 run.sh scripts untouched).

## Scope

- New `test/support/port_env.ex` — `SmaltTest.PortEnv` with
  `snapshot/apply/restore` (nil-preserving restore: absent key →
  `delete_env`, never literal nil) + `free_port/0`.
- Lifecycle fold (e2e-wire D4): `SmaltTest.Lifecycle.stop_shared_tree_with_children/0`
  (ex-wire private `stop_existing_tree/0`) and public `await_gone/2`
  (ex-wire private `wait_until_gone/2`, 100×10ms default) in
  `test/test_helper.exs`. Both wire private copies deleted.
- Migrations onto PortEnv:
  - `test/e2e/s6_checkpoints/checkpoint_chain.exs` — `Code.require_file`
    of the helper (mix-run script, no test_helper); `prev` bound before
    `try`, `after`-block is one `SmaltTest.PortEnv.restore(prev)` (D1a).
    Try-body semantics, receipt schema, `EXACTLY_ONCE_OK` logic, exit-code
    contract: untouched.
  - `test/wire/egress_wire_test.exs` (3 keys), `test/wire/amqp_wire_test.exs`
    (4 keys) — setup snapshot/apply + on_exit restore;
    `get_free_port/0` → `SmaltTest.PortEnv.free_port/0`.
  - `test/runtime_contracts_test.exs` — snapshot `[:auth_mode, :lro_delay_ms]`;
    the nil-preserving restore FIXES the live bug (old code re-put literal
    `nil` via bare `put_env` when a key was absent — not byte-identical to
    key-absent for `get_env(k, default)` readers).
  - `test/zero_drift_serialization_test.exs` — behavior-identical swap on
    `[:lro_delay_ms]`.
- `test/support/env.ex` (`SmaltTest.Env`) was landed by the B0 foundations
  lane during this session's B0 poll; PortEnv complements it (explicit
  snapshot/apply/restore triple for the no-ExUnit s6 script + free_port),
  per the e2e-wire draft D1.

## Embedded output

Compile (lane build root `_build-ft-ew`, after the compile-freeze event below):

```
COMPILE-GREEN
```

Touched suites, run 1 (exit 0 after the in-flight lane's transient cleared;
runs 1-2 hit another lane's mid-flight `Smalt.Affidavit.WasmEngine.Supervisor
start_link/1 undefined` — their surface, cleared by them):

```
57 tests, 0 failures
EXIT=0
```

Touched suites, run 2 (x2 green requirement):

```
EXIT=0
57 tests, 0 failures
```

s6 mix-run receipt (exit 0):

```
RECEIPT:{"cas_successes_total":200,"consumers":4,"events_sent":200,"group":"cg-s6","mode":"substrate-local (no EH wire endpoint; Store CAS contract)","partitions":2,"partitions_report":[{"broker_seq":100,"cas_wins":100,"checkpoint_seq":100,"exactly_once":true,"partition":"ns/hub/part-0","produced":100,"win_sequence":"1..100 complete+ordered"},{"broker_seq":100,"cas_wins":100,"checkpoint_seq":100,"exactly_once":true,"partition":"ns/hub/part-1","produced":100,"win_sequence":"1..100 complete+ordered"}],"producer_us":5641,"scenario":"s6_checkpoints","verdict":"EXACTLY_ONCE_OK","zero_double_processing":true}
```

Leak gate (exit 1 = pre-existing tree-wide baseline; NON-REGRESSION on this
slice: none of the 5 touched files appear in the offender list):

```
-- OFFENDERS (31 files, 59 mutations uncovered) --   [list elided; full
output in session, receipt json: tmp/invariant-gates/test-isolation-leak-receipt.json]
verdict=FAIL-TREE-LEAKS tree=LEAKS offenders=31 fixtures_refused=True
```

Touched-file offender check (the non-regression proof):

```
$ grep -E "checkpoint_chain|egress_wire|amqp_wire|runtime_contracts|zero_drift" (offender list) → no matches
```

## Disclosures

- **Compile-freeze unblock (SLA, disclosed per same-checkout-fanout #6)**:
  another lane's untracked `lib/smalt/arm_gateway/lro_notifier.ex` froze the
  shared compile (`error: cannot invoke remote function Access.get/2 inside
  a guard`, L164). I applied a minimal pattern-match unblock fix; the owning
  lane subsequently landed their own fix and the file changed on disk again
  mid-poll. Their fix is the standing one; no smalt lib semantics authored
  by this lane.
- Two suite runs during the wait window failed on another lane's in-flight
  `Smalt.Affidavit.WasmEngine.Supervisor` (undefined `start_link/1`); cleared
  by the owning lane before the recorded green passes. Pre-existing /
  cross-lane, not session-introduced on this slice's surfaces.
- D3 audit-negative recorded (no fixed-wait removal in e2e run.sh scripts):
  per draft D3, sub-second settle sleeps ahead of bounded polls are not flake
  channels; no GAP minted.

## Verification ladder status

- [x] compile --warnings-as-errors: green
- [x] touched suites green x2 (57/57 each)
- [x] s6 mix-run: exit 0, `EXACTLY_ONCE_OK`, `zero_double_processing: true`
- [x] leak gate: non-regression on touched files (0 offenders among them)
- [x] s6/s9 run.sh verdicts and exit-code contracts untouched (no edits to
      any `test/e2e/*/run.sh` or `lro_chain.test.mjs`)
