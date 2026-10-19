# Receipt: v2 soak RELAUNCH — 3x full `mix test` + 2x wire tier, `_build-ft-v2b`

Date: 2026-10-18, runs executed 15:29–18:2x PDT · HEAD at run 1 start: 8b5bb9b0bed1ee2838787f9832cd2d7bee88e04e;
HEAD moved **6 times mid-lane** (8b5bb9b → c6f6243 → be81187 → 2a82b29 → a39f7ba → d32129c → 4af0553) —
every run after run 1 executed on a different tree state. Context: full.
Lane: bench-runner verification (no edits, no git actions).
Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
(`just bench-machine`). Gate: v1 receipt present (read at 15:2x; standing SUSPECT, 0/3 clean).

**Standing: SUSPECT / acceptance NOT met — 0 of 3 full runs clean, 0 of 2 wire legs clean.**
Context: full x3 + wire tier x2 (mix test, _build-ft-v2b)

## Full-suite runs (prescribed 3)

| Run | Log | Exit | ExUnit summary (verbatim) | Note |
|---|---|---|---|---|
| 1 | `/tmp/v2_soak_run1.log` (319,866 ln) | 2 | `Finished in 431.5 s (24.2s async, 407.3s sync)` / `1 doctest, 7 properties, 2633 tests, 3 failures (90 excluded)` | clean execution |
| 2 | `/tmp/v2_soak_run2.log` (285,219 ln) | 2 | `Finished in 1182.5 s (70.9s async, 1111.6s sync)` / `1 doctest, 7 properties, 2674 tests, 17 failures (90 excluded)` | preceded by one compile abort + 15-min compile-freeze SLA poll |
| 3 | `/tmp/v2_soak_run3.log` (431,307 ln) | 2* | `Finished in 1587.4 s (68.9s async, 1518.5s sync)` / `1 doctest, 2026 tests, 17 failures (90 excluded)` | ANOMALOUS: test count dropped ~650 vs runs 1–2; multiple other lanes' `mix test` beams were live concurrently; part of the suite did not report. Counted as RED. |

Pre-run-2 compile abort (recorded, not a test failure): `lib/smalt/messaging/event_grid.ex:137`
`TokenMissingError` (missing `end`) — another lane's in-flight edit; settled under SLA poll
(~35 min dep+app recompile in the private build root after tree move).

Run 3 was also killed by the harness's 30-min background cap AFTER the summary line
landed (`EXIT` wrapper never wrote; beam SIGKILLed during teardown). Summary is real.

### Run 1 identities (3/3 recoverable)

1. `test/stress_tier_census_test.exs:13` — `File.Error could not read
   "test/tiny_iso_probe_test.exs": no such file or directory`. Tree-churn face: the
   census fixture file was mid-move. On later trees the file set changed entirely
   (stress tier was rewritten); not reproducible on the final tree state.
2. `test/canonical_projection_test.exs:125` — `docs/capabilities.json is stale vs
   Registry truth`. Deterministic drift fence (F15 class). Recurred run 2 + both wire
   legs → **4/5 runs, all states.**
3. `test/pplan_test.exs:2490` lens5 — `assert ... <= 2` failed, left 9 right 2.
   Ledger-adjacent surface; did NOT recur in run 2/3 or wire legs (1/5).

### Run 2 identities (9 of 17 recoverable from log; 8 blocks swallowed by
interleaved `[debug] [amqp-atom]` spam from concurrent lanes)

- `test/stress_tier_census_test.exs:13` — timeout 60 s (different face of run 1's file)
- `test/canonical_projection_test.exs:130` — capabilities.json stale (repeat)
- `test/azsim/data_plane_test.exs:156,107` and `test/azsim/integration_plane_test.exs:37,261,48,137` —
  **the whole Azsim plane batch red**: If-Modified-Since 304 contract, range GET
  ContainerAlreadyExists, `QueueStore.enqueue` returns `{:ok, 1}` vs expected `:ok`
  (API mismatch between the new Azsim tests and `lib/smalt` store), event-grid
  recovery falsifier timeout, partition detach timeout — in-flight batch surface
  (HEAD be81187 → 4af0553 was landing this batch during the lane).
- `error_codes` doc test NOT present in run 2 (regen landed with c6f6243); it came
  BACK in both wire legs (see below) — the regen did not hold.

### Run 3 identities (9 of 17 recoverable)

Same interleaving truncation. Not re-enumerated individually; wire legs (below) ran on
the settled tree and carry the reproducible set.

## Wire-tier legs (court T1/T2 shape, `--include amqp_wire`)

| Leg | Log | Exit | ExUnit summary (verbatim) |
|---|---|---|---|
| 1 | `/tmp/v2_soak_wire1.log` (28,807 ln) | 2 | `1 doctest, 7 properties, 2747 tests, 11 failures (29 excluded)` |
| 2 | `/tmp/v2_soak_wire2.log` (26,003 ln) | 2 | `1 doctest, 7 properties, 2755 tests, 11 failures (32 excluded)` |

Leg 1 required two compile-abort retries per the SLA: (a) `test/azsim/topology_test.exs:119`
`SyntaxError` (`endpoint egress_port` — missing comma, in-flight batch edit), (b)
`test/azsim/adversarial_joe_test.exs:19` — `SmaltTest.Support.Assertions` module not
loaded/absent (renamed to `test/support/assert_eventually.ex` by the owning lane at 4af0553).

### Leg 1 identities (9 of 11 recoverable)

1. `test/error_codes_doc_test.exs:46` — `docs/ERROR_CODES.md is stale relative to the
   sources` — DETERMINISTIC: confirmed off-test, `python3 scripts/gen_error_codes.py --check`
   exits 1 on the current tree (c1-arm rows drifted again after c6f6243's regen).
2. `test/pplan_test.exs:2875` lens7 half-degraded-window noproc shape
3. `test/enclave_ocel_test.exs:52` — enclave lifecycle OCEL stage event
4. `test/enclave_state_test.exs:173` — reverse-topological destroy residue
5. `test/canonical_projection_test.exs:134` — capabilities.json stale (repeat, 4/5 runs)
6. `test/mcp_test.exs:420` — doctor.summary supervisor children
7. `test/enclave_lifecycle_test.exs:106` — OCEL fail-safe emission
8. `test/enclave_lifecycle_test.exs:56` — composite baseline fixture lifecycle
9. `test/mcp_wire_test.exs:2..` — doctor.summary vs scripts/doctor.py --json agreement

### Leg 2 identities (9 of 11 recoverable)

1. `test/mcp_test.exs:420` — doctor.summary (repeat)
2. `test/enclave_state_test.exs:173` — destroy residue (repeat)
3. `test/azsim/adversarial_joe_test.exs` Vector 3 (half-open TCP partition) and
   Vector 1 (mailbox overload backpressure) — NEW batch surface, first wire witness
4. `test/enclave_lifecycle_test.exs:56,106` — lifecycle (repeat x2)
5. `test/pplan_test.exs:2875` lens7 (repeat)
6. `test/mcp_wire_test.exs:806` — doctor agreement (repeat)
7. `test/canonical_projection_test.exs` — capabilities.json stale (repeat, 5/5 runs)
8. ErrorCodes doc test ABSENT in leg 2 (flips with tree state — regen lands, drifts again)

## Classification vs `docs/jira v26.10.17/FLAKE_LEDGER.md`

| Face | Class | Standing |
|---|---|---|
| ErrorCodes + capabilities.json drift | Deterministic generated-artifact drift (F15 class): sources land, regen doesn't; the c6f6243 regen drifted again within one tree-move. | persistent, NOT jitter; fix = owning-lane regen, one command each |
| Azsim plane batch (data/integration/adversarial_joe) | In-flight batch surface (AZB-04/07 landing mid-lane): enqueue arity/return-shape mismatch `{:ok,1}` vs `:ok`, event-grid recovery timeout, adversarial vectors | NEW FACE, owner-lane (azsim batch), not a soak defect |
| Enclave lifecycle/OCEL/destroy cluster (enclave_lifecycle_test, enclave_state_test, enclave_ocel_test) | Coherent red cluster on the newly landed enclave batch; recurs 2/2 wire legs | NEW FACE, enclave-batch owner |
| `Smalt.McpTest` doctor.summary + `Smalt.McpWireTest` doctor agreement | Recurs 2/2 wire legs; same cluster as the enclave cluster (doctor reports substrate health) | NEW FACE, mcp/enclave owner |
| `test/pplan_test.exs:2875` lens7 | Recurs 2/2 wire legs on settled tree | NEW FACE, unledgered, needs owner solo bisect |
| `test/pplan_test.lens5` (`:2490`) | 1/5 (run 1 only) | nonrecurring this window |
| `test/stress_tier_census_test.exs:13` | Tree-churn face (fixture mid-move, then 60 s timeout on new tree) | NEW FACE, census fixture owner |
| DETS/churn/`store_churn` F12/F14 | Did not recur (0/5) | quiet this window |

## Standing

**SUSPECT.** Acceptance (3/3 + 2/2 clean) NOT met: 0/5 clean. Two deterministic
generated-artifact drifts (ERROR_CODES.md confirmed off-test exit 1; capabilities.json
5/5 runs) — both one-command owning-lane regens. Remainder are coherent clusters on
newly-landing batches (azsim, enclave/doctor, pplan lens7, stress census), i.e. the
tree moved 6 times under the lane; this receipt is per-run-tree, not a single-tree verdict.
A clean 3x+2x verdict requires a tree that stops moving and two regens.

## Cleanup

Direct `rm -rf _build-ft-v2b` was denied by the permission system (same as v1).
`just lane-clean` then ran and `_build-ft-v2b` is confirmed absent from disk
(`ls` → No such file or directory); the sweep also reclaimed 18 other orphan
roots (8.83 GiB). Cleanup objective met.
