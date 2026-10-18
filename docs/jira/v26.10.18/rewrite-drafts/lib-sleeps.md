# Draft: lib/ Process.sleep inventory — v26.10.18 (NO-SLEEP-DOCTRINE)

Source: read-only inventory lane, 2026-10-18. Six hits in lib/; LRO lazy
completion has NO sleep (delayMs is data evaluated on the sweeper send_after
tick = SCHEDULING, keep).

| # | File:Line | Waiting for | Class |
|---|---|---|---|
| 1 | lib/smalt/arm_gateway/router.ex:2259 | FinOps.Calculator module load | SIGNALABLE |
| 2 | lib/smalt/enclave/state.ex:165 | LRO terminal status (verify harness) | SIGNALABLE (latent bug: inverted predicate — polls hot on 202, sleeps after terminal) |
| 3 | lib/smalt/enclave/doctor.ex:183 | Sweeper eviction visibility | SIGNALABLE |
| 4 | lib/smalt/enclave/doctor.ex:259 | LRO terminality poll | SIGNALABLE |
| 5 | lib/smalt/affidavit/wasm_engine.ex:99 | NIF teardown window | CONTRACT |
| 6 | lib/smalt/pplan/task.ex:154 | Named-GenServer init creating ETS | SIGNALABLE |

## Redesigns
1. FinOps: supervision-tree readiness flag via persistent_term from the lane's
   handle_continue; router fails closed to proxy_tariff instantly when not ready.
2-4. **LRO.await(op_id, timeout)** — one monitor/registry in the LRO subsystem,
   notify-on-terminal emitted exactly where maybe_finalize flips the record.
   Deletes three sleeps AND fixes the state.ex:165 inverted predicate. (Sites
   3: eviction_pass finalizes-then-evicts atomically instead of sleep-then-evict.)
5. wasm engine: preferred — terminate/2 performs NIF teardown synchronously so
   restart is deterministic ("terminate returned" IS the readiness signal);
   fallback — readiness probe (af_abi_version call) as the retry exit condition,
   bounded retry documented as CONTRACT.
6. pplan task: init creates the table, handle_continue does the rest; clients
   handshake via GenServer.call(pid, :ready) — the race terminates on a
   message, not a clock.

## SCHEDULING (legitimate, keep untouched)
lro_sweeper ticks, telemetry prune, dets_mirror flush, amqp listener reconnect
backoff, amqp sweeper — all Process.send_after (message scheduling), never
blocking waits.
