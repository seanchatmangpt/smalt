# L11 — AoQ supervisor skeleton (Smalt.Aoq.Supervisor subtree)

Standing: ALIVE

Command: `MIX_BUILD_ROOT=_build-lane11 mix test test/smalt/aoq/supervisor_test.exs`
Exit 0. Embedded output (run this session, 2026-11-04):

```
...
Finished in 0.1 seconds (0.00s async, 0.1s sync)

Result: 7 passed
```

Commit: see git log subject `aoq(l11):`. Branch: main, pushed to origin
(verified via `git ls-remote | grep HEAD_sha`).

## Scope landed (spec §1 process topology)

- `lib/smalt/aoq/supervisor.ex` — one_for_one root; boot order
  NifHolder → WorkerPool → Listener (holders/pool before the wire face).
  Config-gated OFF by default (byte-identical boot); port pin 9093 default
  (9092 is the Kafka face), ephemeral under test via `:aoq_port` probe.
- `lib/smalt/aoq/worker_pool.ex` — fixed one_for_one pool of stateless
  GenServer-free workers; :atomics round-robin dispatch + seq lease
  (`add_get`-only, spec §6 law); workers pull from their mailbox.
- `lib/smalt/aoq/worker.ex` — plain process; NIF seam via behaviour
  (`Smalt.Aoq.Nif`), never a direct NIF call. `:erlang.spawn_opt` with
  `:link` (binds worker to pool supervisor at spawn — spawn_opt/2 does not
  link by default; without it a killed worker is never restarted, caught by
  the crash-restart test), off_heap MQD, max_heap_size budget, GC heartbeat
  (SLEEP-CLASS: POLL-STEP).
- `lib/smalt/aoq/nif_holder.ex` — behaviour seam (`Smalt.Aoq.Nif`) + pure
  placeholder `Smalt.Aoq.Nif.Stub` (enforces >64B framing law, iolist
  egress `[h | p]`) so the LANE-02 NIF plugs in without rework.
- `lib/smalt/aoq/listener.ex` — datagram wire face (phase-1 UDP per
  aq-quic-transport-decision.md), bound-poll readiness via
  `local_port/0` observable, typed refusal on bind failure, idle-deadline
  give-up (no Process.sleep; runtime-owned recvmsg timeout).
- Wiring: `lib/smalt/plane/data_supervisor.ex` mounts `Smalt.Aoq.Supervisor`
  as the single lawful start site (config-gated, default OFF);
  `Smalt.Application.aoq_child/0` retired to `[]` (posh precedent) so the
  subtree cannot double-start.

## Shared-surface disclosure (same-dir concurrent lanes)

`lib/smalt/aoq/` was a contested shared surface during this session: L9
(flags.ex, scheduler.ex, rel/vm.args.eex, application.ex SMALT_AOQ_FLAGS
hunk), L12/L13/L15 (frame/tables/cursor/arrow, bin-opt gate, framing court)
left untracked in-flight code in the same dir. This commit lands the
compile-closure set for the L11 supervisor face (including flags.ex, which
`application.ex`'s in-tree L9 hunk requires, and listener/transport, which
carry SLA unblocks disclosed below). L9's `test/internal/aoq_vm_flags_test.exs`
+ `rel/vm.args.eex` and L13/L15 test files remain UNTRACKED — not staged,
they are those lanes' surfaces.

Compile-freeze SLA unblocks applied to other lanes' in-flight files,
disclosed per the fan-out law:

- `transport.ex`: `{:erlang.io_list, io}` invalid-pattern compile error →
  `iovec: [frames]` + single-clause `extract_payload/1`; missing `refuse/1`
  was fixed forward by its owner mid-session; `:socket.sockaddr_in` tuple
  tag (invalid remote-call-in-tuple / prim_socket refusal) → sockaddr map
  `%{family: :inet, addr:, port:}` (same fix class in listener.ex).
- `listener.ex`: `case ... {` syntax error was fixed forward by its owner
  mid-session; sockaddr map fix applied here.
- `worker.ex`: C4 hardening (off_heap MQD, max_heap_size, GC heartbeat) is
  L20's mid-flight edit, fixed forward + `:link` spawn opt added here.

## Tests (7/7 green, Chicago-style: real sockets, real processes)

1. boots full one_for_one subtree (listener bound, pool live, holder alive)
2. real UDP datagram reaches a pool worker via the sink
3. worker crash is a restart, never data loss
4. stub parse enforces >64B framing law
5. stub encode emits iolist egress, byte-identical to concat
6. zero-width pool refuses typed (`:pool_empty`)
7. config defaults (port 9093 pin, schedulers-sized pool)

## Falsifier checks

- No Process.sleep anywhere in lib/smalt/aoq (SLEEP-CLASS annotations only).
- Known-open: 13 failures remain in OTHER lanes' untracked test files
  (iovec_court/listener/session — `{:transport_refusal, :ok}` wrapping and a
  WorkerPool child-spec compile-order issue); not L11's surface, left
  untracked for their owners.
