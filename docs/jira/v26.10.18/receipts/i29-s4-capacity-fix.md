# i29 — s4-amqp-capacity burn face: per-conn atom-bridge log flood

Standing: PARTIAL_ALIVE (in-process verification green ×2; docker-blocked burn rerun pending)

Context: pair(repo=/Users/sac/smalt, lanes: i29 capacity-face lane; docker unavailable)

Machine: {"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}

## Defect

azb-17 parallel-matrix integration cell exits rc=1 with
`flood_conns=2073 atom_log_lines=2073` (docs/jira/v26.10.18/receipts/azb-17-parallel-matrix.md).
The atom-bridge serve loop logged one debug line **per flood connection**.

## Root cause (premise rot, not QueueStore)

QueueStore's capacity path is clean — `enqueue/3` returns typed
`{:error, :capacity}` with zero logging (repro confirmed: 4097th enqueue typed-refused,
`queue_info.capacity == 4096`, no log output). The flood lives one layer down:
in `lib/smalt/messaging/amqp/atom_bridge.ex` `serve/2` the **i22 silent-`:closed`
clause had been dropped** — the comment block still claimed i22/i23 silence while
`:closed` fell into the catch-all `Logger.debug("[amqp-atom] request read failed: ...")`.
The burn flood shape (`PUT /flood HTTP/1.1\r\n` then close) hits exactly the
`:closed` terminal path, so every flood connection minted one log line:
atom_log_lines == flood_conns exactly.

## Fix

`lib/smalt/messaging/amqp/atom_bridge.ex` `serve/2`:

1. Restore the i22 clause: `{:error, :closed} -> :ok` (terminal, silent).
2. The remaining catch-all debug path (non-terminal read faults: `:too_large`,
   `:bad_content_length`, odd recv faults) is now :once-rate-limited per reason
   over `:persistent_term` (5s window): first occurrence logs `inspect(reason)`,
   repeats collapse to a static `"(aggregated)"` suffix. Ownerless persistent
   term, no ETS-owner race from short-lived serve tasks; no atom minting (the
   key is the existing error atom).

## Red→green witness (in-process, docker disk-blocked)

Pre-fix (`MIX_ENV=test` ephemeral-port boot, 300 flood conns, /tmp/s4_repro.log):

```
S4_ENQUEUE_4097={:error, :capacity}
S4_CAPACITY=4096 OK
FLOOD_CONNS=300
request read failed: 300   # atom_log_lines == flood_conns, burn face reproduced
```

Post-fix (same harness, /tmp/s4_green.log):

```
S4_ENQUEUE_4097={:error, :capacity}
S4_CAPACITY=4096 OK
FLOOD_CONNS=300
request read failed: 0
amqp-atom: 0
```

Payload-shape bisection (`/tmp/atom_iso4.exs`): partial-then-close flood — the
burn's exact shape — now mints **0 atoms steady-state** (3×300 conns: 345/0/0;
first burst is one-time VM warming, disclosed) and **0 log lines**. Full valid
HTTP PUTs (a different, legal workload that creates queues) still cost ~1
atom/conn on first touch — noted, out of scope here, not the burn face.

## Verification

- queue-capacity invariant gate ×2, each spawning its own live substrate,
  3 negative fixtures refused (non-vacuous):

```
queue-capacity: receipt /Users/sac/smalt/tmp/invariant-gates/queue-capacity-receipt.json verdict=PASS
GATE_RC=0    # run 1 and run 2
```

- Focused offline tier (atom_bridge + queue_store): `59 tests, 0 failures`
- Full amqp offline tier: `336 tests, 0 failures (45 excluded)`
- New tests in `test/amqp/atom_bridge_test.exs`:
  - "flood of closed mid-request connections is silent (i22 restored)" —
    30 real serve/2 sockets, asserts 0 "request read failed" lines
  - "non-terminal read faults log once per window, repeats aggregated" —
    asserts `:too_large` logged once, repeat rendered "(aggregated)"

## Pending court

docker is disk-blocked this session: the azb-17 integration cell rerun
(`docker/burn/parallel-matrix.sh --replicas 1`) is the outstanding court for
the full flip to ALIVE. The in-process repro + gate + offline tiers are the
acceptance for this lane.

## Pinions preserved

SASL ANONYMOUS only, sasl-outcome 0x44, attach-arity tripwires, .NET-GUID
lock tokens, EH partitions ["0","1"] — untouched. No git operations. Lane
build root `_build-lane29` only.
