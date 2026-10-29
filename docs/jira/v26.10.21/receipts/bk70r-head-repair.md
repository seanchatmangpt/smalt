# BK-70r Head Repair (relaunch)

**Standing: PARTIAL_ALIVE** — all five BK-70r defect classes fixed with in-context verification;
terminal full-green sweep NOT sealed: runs 1–7 each raced concurrent-lane churn landing mid-run
(compile breaks, unregistered test files, port contention), leaving a final census-drift residue
owned by the AZ/EXPL-3 lanes.

**Context: full** — solo gate runs (ja15, census, ets_auto, amqp10_debug, 3-file group, pairs) plus
7 full-suite runs (`/tmp/bk70r_run*.log`, run 1 was `/tmp/bk70r_full_suite.log`).

## Fixes landed (checkpointed by the coordinator, no direct commits by this lane)

| Fix | File | Evidence |
|---|---|---|
| ja15 hostile-formatter restore bug (restore re-read the hostile config and "restored" HostileFormatter onto itself, smearing default-handler crashes across the rest of the suite) | `test/internal/ja15_error_logger_court_test.exs` | solo 10/10 pre and post; formatter captured BEFORE overwrite, restore uses that |
| BK-70r orphan-reclaim + mortal shim: `unlinked_start` minted an immortal unlinked `GenServer.start` owner; surviving an app stop/start cycle it held `EHServer` name forever, every supervised boot failed `:already_started`, IntegrationSupervisor exited, whole-plane app-exit cascade | `lib/smalt/messaging/event_hubs.ex` | run 1: 4x "Application smalt exited … already started PID<0.6391.0>" + 25 store_not_ready smear. Runs 4–7: ZERO `already started` app-exits; the only exit is a lawful `:shutdown` bounce |
| Census observables allowlist missing BK-109b's ja15 G2 refs (deterministic, reproducible solo) | `test/internal/internal_tier_census_test.exs` | census solo 5/6 before, 6/6 after |
| amqp10_debug `grab/4` improper-list helper bug (`[f \| {_,_}] |> List.flatten()` always FunctionClauseError) + unguaranteed trailing "extra frame" recv leg (recv `:timeout`) | `test/integration/amqp10_debug_test.exs` | 0/1 → 1/1 solo |
| bk69r probe inline sleep-paced wait → audited bounded poll (`test/internal/poll_helper.exs`) | `test/integration/bk69r_probe_start_test.exs` (was bk69r_probe_tmp) | sleep-gate violation count 6 → 2 (rest were other-lane scratch) → PASS |
| ts probe deadline guards annotated `// SLEEP-CLASS: POLL-STEP` (deadline guards bounding event waits, typed failure on expiry) | `verification/ts/bk65.probe.cjs` | sleep-gate PASS — 565 files, 0 unclassified sleep primitives |
| kafka `conn.ex` same-pattern pin bug (`binary-size(^tlen)` etc. — caret on same-pattern bindings is a compile error), 5 sites | `lib/smalt/messaging/kafka/conn.ex` | tree compile restored; checkpointed at 46024dd ("kafka conn.ex SLA unblock folded") — compile-freeze SLA fix, disclosed per fanout law §6 |

## Gate ladder (final states)

| Gate | Result |
|---|---|
| `just sleep-gate` | **PASS — 565 files, 0 unclassified sleep primitives** (BK-35's 5 ja12/ja13 violations resolved: 2 restructured to the audited poll, 3 ts deadline guards typed POLL-STEP; remaining 2 were another lane's scratch file, since deleted by its owner) |
| `just invariant-gates` | **PASS 6/6** (positive held + all negative fixtures refused) |
| `just docs-dod-check` | PASS (exit 0, twice) |
| `just receipt-index` | ran clean, INDEX.md regenerated |
| Full suite | **NOT GREEN — BLOCKED by cross-lane churn** (below) |

## Full-suite ledger (7 runs)

- Run 1: ~201 failures — EHServer orphan cascade (4 app-exits, 25 store_not_ready smear) + hostile-formatter smear. ROOT-CAUSED and FIXED (see above).
- Run 2: 13 failures, disjoint set — cross-lane load interference (other lanes' beams live; "sb connection cap reached (2/2)"; KD-115 put-token timeout).
- Run 3: 124 failures, 2 fresh-pid `already started` app-exits — reap lost the re-mint race → strengthened to ancestor-check reaper + mortal shim mint (fix v2). Verified: runs 4–7 zero such exits.
- Run 4: 32 failures, 0 EHServer exits — single lawful `:shutdown` bounce smear + order/load-dependent set (KD-124 `:code.delete` race, SPOF-3.2 engine-busy timing, TLS-twin contention).
- Run 5: compile-abort — AZ wave landed broken `kafka/records.ex`/`conn.ex` mid-run (conn.ex fixed by this lane under SLA; records.ex self-fixed by AZ lane).
- Run 6: compile-abort — `webpubsub_test.exs` backslash syntax artifact mid-edit (self-fixed by owner).
- Run 7: **3 failures, all census drift from the AZ/EXPL-3 wave's new test files** (population fence: az2_maa/az4_mhsm/expl3_dataplane_repairs/webpubsub unregistered; forbidden-client-token and status-literal gates against the same files) + in-flight syntax error `test/integration/az3_confidential_ledger_court_test.exs:210` (unexpected option :rescue in case).

## Residual (dispatch back to owning lanes — not this lane's surfaces)

1. AZ/EXPL-3 wave test files: census registration + their own client-token/status-literal reconciliation
   (registering their files is bookkeeping; exempting their violations would weaken the gates —
   the authoring lane must reconcile).
2. `test/integration/az3_confidential_ledger_court_test.exs` (and `az3b_ledger_mount_court_test.exs`,
   `test/internal/kafka_wire_test.exs`, `config/test.exs`) in-flight on disk — the sweep cannot seal
   while shared-tree files are being authored mid-run.
3. Post-46024dd census re-check on current tree: 1/6 — the newer AZ checkpoints added more
   unregistered files; census drift is growing, not shrinking, under the current wave.

## Replay

```
export PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
MIX_BUILD_ROOT=_build-bk70r mix test          # run 7 = /tmp/bk70r_run7.log (3 census failures)
just sleep-gate                               # PASS 0 violations
just invariant-gates                          # PASS 6/6
just docs-dod-check && just receipt-index     # PASS
```

Logs: `/tmp/bk70r_full_suite.log` (run 1) and `/tmp/bk70r_run{2..7}.log`.

**Falsifier for the cascade fix**: any future full-suite run with an
`Application smalt exited … already started` EHServer line falsifies the orphan-reclaim fix.
Runs 4–7 (4 consecutive full runs) are clean on that signature.
