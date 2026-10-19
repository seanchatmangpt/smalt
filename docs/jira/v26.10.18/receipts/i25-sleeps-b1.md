# Receipt — i25-sleeps-b1: §B1 inherent time-advance, named + parameterized windows

Standing: PARTIAL_ALIVE (all owned sites landed and green x2; 4 lro sites superseded mid-flight by i25-lro-backdate; 2 disclosed unblock edits)
Context: slice(owned sleep-window files: c1_arm.exs, smalt_arm_gateway_test.exs, arm_error_corpus_test.exs, sweeper_test.exs, mcp_wire_test.exs, lro_test.exs — 2 runs)
Lane: i25-sleeps-b1 (lease: rewrite-drafts/sleeps.md §B1, 13 sites)
Date: 2026-10-18

## Scope executed

New shared helper `test/support/sleep_windows.ex` (`SmaltTest.SleepWindows`),
each window a named, @doc'd function derived from its configured constant
(never a bare literal at the call site):

| window fn | law (@doc) | call sites |
|---|---|---|
| `second_boundary_ms/1` | wall-clock 1 s fixed-window alignment (rate limiter admit count assertable only inside one window) | c1_arm.exs:410, smalt_arm_gateway_test.exs:1287, arm_error_corpus_test.exs:477 |
| `fixed_window_rollover_ms/0` | full 1 s window rollover / counter reset (fixed window, not permanent ban) | c1_arm.exs:434 |
| `lro_delay_elapse_ms/2` | LRO delay elapse before sweep/poll | (4 lro_test sites — see Superseded) |
| `lro_deadline_elapse_ms/0` | LRO deadline elapse before at-rest sweep | (enclave — see Adjusted) |
| `sweeper_grace_elapse_ms/0` | tombstone grace elapse (`amqp_sweeper_lock_grace_ms` + 4 ms epsilon) | test/amqp/sweeper_test.exs:87 |
| `mcp_idle_gap_ms/0` | wire keep-alive idle gap (`:mcp_idle_keep_alive_gap_ms`, default 1500) | test/mcp_wire_test.exs:956 |

## Sites, final state

- test/compliance/c1_arm.exs:410/:434 — both sleeps parameterized
  (`second_boundary_ms(5)`, `fixed_window_rollover_ms()`), annotation names
  the window. Semantics preserved exactly (align-to-next-boundary; roll to
  next window +100 ms margin).
- test/smalt_arm_gateway_test.exs:1287 and test/arm_error_corpus_test.exs:477
  — `wait_for_fresh_window` now derives from `second_boundary_ms(20)`
  (error-corpus replaces its fixed 300 ms with the same boundary law;
  boundary still crossed in all cases).
- test/amqp/sweeper_test.exs:87 — `sweeper_grace_elapse_ms()` =
  `get_env(:amqp_sweeper_lock_grace_ms, 1) + 4` (was literal 5; derives from
  the configured grace).
- test/mcp_wire_test.exs:956 — 1500 ms literal parameterized via env
  `:smalt, :mcp_idle_keep_alive_gap_ms` (default 1500, unchanged).
- test/enclave-testbed/enclave_testbed.exs:621 — deadline window inlined as
  `get_env(:lro_delay_ms, 15) * 4` (was literal 60; identical under the
  phase-E2 `put_env(..., 15)`); named per B1. Inlined (not the support
  module) because run.sh uses `mix run`, where test/support is not on the
  code path — witnessed: support-module form FAILs E2 with
  `SmaltTest.SleepWindows.lro_deadline_elapse_ms/0 is undefined`.
- test/amqp/queue_store_test.exs:607/:611 — ALREADY REWRITTEN (i21d): the
  lock original-vs-renewed expiry choreography sleeps were replaced by
  read-back contracts; no sleeps remain at those lines. Checked before
  editing; nothing to do.
- **Superseded**: the 4 lro_test.exs sites (651/672/701/734) were rewritten
  mid-flight by the concurrent i25-lro-backdate lane (BACKDATE: completion is
  record+clock-pure — startedAtMs shifted into the past instead of sleeping
  out the delay window). That removes the sleeps entirely — strictly better
  than B1 keep+parameterize. I did not re-apply my parameterization over it.
  My `lro_delay_elapse_ms/2` remains in the support module (used by no site
  after the supersession — kept as the named law for the class; if the
  register wants it deleted, delete with the lro lane).

## Disclosed unblock edits

1. enclave_testbed.exs:40-44 — added `:mcp_port` (29445) to the private-port
   pin set: the MCP surface port was missing from the private set, so a
   concurrent default-port substrate on 9545 collided (:eaddrinuse,
   witnessed twice). Same-file, minimal, disclosed here.
2. test/lro_test.exs — two formatter blank-line insertions at my (now
   superseded) hunks; superseded file state is owned by the backdate lane.

## Validation (real output)

Env: MIX_BUILD_ROOT=_build-ft-sb1 (private; RECLAIMED at integration per
cleanup law).

Run 1 (ExUnit set: lro + gateway + error-corpus + mcp_wire + sweeper +
c1_arm):

    158 tests, 3 failures

Run 2:

    158 tests, 1 failure

Failure classification:
- test/mcp_wire_test.exs:806 doctor.summary — PRE-EXISTING on this tree:
  fails identically with the HEAD version of the test file (exit 2). Not
  session-introduced by this lane (no mechanism touches
  supervisor_children). Owner: mcp/planes lane.
- lro_test.exs:1204 / :4249 — pass in isolation after load-flake under
  concurrent lanes (targeted rerun: `5 tests, 1 failure` where the 1 is the
  pre-existing doctor test; both lro tests green). Also green in run 2.
- My owned sites (c1_arm both windows, gateway, error-corpus, sweeper,
  mcp keep-alive) green in BOTH runs.

Enclave testbed (`bash test/enclave-testbed/run.sh`), run 1 exit 0, run 2
exit 0; run 2 on the shared root after ft-sb1 was poisoned by a mid-landing
compile of another lane's `Smalt.Semantic.R2RMLGuard` (shared root compiles
green). Both runs:

    PASS  A: SKR attest->release->replay
    PASS  B: WORM legal-hold + immutability
    PASS  C: Confidential Ledger chain
    PASS  D: Governance (Purview/Sentinel/RG)
    PASS  E1: Cosmos 500-doc cross-partition
    PASS  E2: 50x LRO + sweeper convergence
    PASS  F1: SB sessions + DLQ under EH load
    PASS  F2: EH producer/consumer + CAS contention
    PASS  F3: chaos — sweeper child kill

(verbatim from /tmp/sb1_enclave2.log; run 1 identical shape)

Gate:

    [SLEEP-GATE] PASS — 330 files, 0 unclassified sleep primitives
    gate=0

Format: touched ExUnit files format-clean at my hunks (lro_test /
smalt_arm_gateway_test / arm_error_corpus_test were ALREADY not
format-clean at HEAD — verified `mix format --check-formatted` fails on
`git show HEAD:file`; pre-existing, left untouched to avoid cross-lane
churn).

## Falsifier

The named windows are real: revert any site to its bare literal (e.g.
`Process.sleep(1100)` at c1_arm) and the sleep-gate still passes (annotation
only) — the named-window law is enforced by this receipt + the support
module's @doc contracts, not yet mechanically; a mechanical gate (window
literals must resolve to SleepWindows fns or annotated constants) is the
follow-on if the register wants teeth.
