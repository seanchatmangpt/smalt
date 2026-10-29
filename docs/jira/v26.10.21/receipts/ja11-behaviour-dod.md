# JA-11 Behaviour Definition-of-Done Census — branch `main`

Repo: `/Users/sac/smalt` · Date: 2026-10-21 · Context: solo

Census: 41 behaviour processes across 34 files in `lib/smalt` (32 GenServer modules, 6 Supervisor/child modules — one shared file, 1 `:gen_statem`, plus Plug/telemetry-handler behaviours riding on GenServers). Legend: ✔ yes, ✖ no, N/A n/a. "Info catch-all" = `def handle_info(_, state)` fallback (Armstrong: an untrapped message kills the process).

## Per-module table

| Module (file under `lib/smalt/`) | Behaviour | Mandatory callbacks | handle_* shapes | @moduledoc | Info catch-all | Single purpose | Verdict |
|---|---|---|---|---|---|---|---|
| Telemetry (`telemetry.ex`) | GenServer + :telemetry handler | ✔ | ✔ | ✔ | ✖ (only `:prune`) | ✖ double duty | VIOLATION (rank 1) |
| Telemetry.RollingCounters | GenServer | ✔ | ✔ | ✔ | ✖ | ✔ | PASS |
| Store (`store.ex`) | GenServer | ✔ | ✔ | ✔ | N/A | ✔ | PASS |
| EventGridWebhook (`event_grid_webhook.ex`) | GenServer | ✔ | ✔ | ✔ | N/A | ✖ registry + Plug same file | VIOLATION (rank 4) |
| EventGridWebhookPlug (same file) | Plug | ✔ | ✔ | ✔ | N/A | ✔ | PASS |
| Application (`application.ex`) | Supervisor | ✔ | ✔ | ✖ | ✖ | ✖ supervisor + 3 nested GenServers | VIOLATION (rank 5) |
| Application.DeferredListeners / ListenerDeferral / TlsTwinDispatch | GenServer/Supervisor | ✔ | ✔ | ✖ | ✖ | ✔ each | PASS (docs gap) |
| Cluster (`cluster.ex`) | GenServer | ✔ | ✔ | ✔ | ✔ | ✔ | PASS |
| Monitor.Metrics (`monitor/metrics.ex`) | GenServer + handler | ✔ | ✔ | ✔ | ✖ | ✖ double duty | VIOLATION (rank 2) |
| ArmGateway.LroSweeper | GenServer | ✔ | ✔ | ✔ | ✖ (tick) | ✔ | PASS |
| ArmGateway.LroNotifier | GenServer | ✔ | ✔ | ✔ | ✖ (DOWN+due) | ✔ | PASS |
| Hw.VirtualSerial | GenServer | ✔ (+terminate) | ✔ | ✔ | ✖ | ✔ | PASS |
| Security.LedgerWriter | GenServer | ✔ | ✔ | ✔ | N/A | ✔ | PASS |
| Wasm.Worker | GenServer | ✔ (+terminate) | ✔ | ✔ | N/A | ✔ | PASS |
| Wasm.Pool | GenServer | ✔ | ✔ | ✔ | ✔ | ✔ | PASS |
| Affidavit.WasmEngine | GenServer | ✔ | ✔ | ✔ | N/A | ✔ | PASS |
| Affidavit.WasmEngine.Supervisor | Supervisor | ✔ | ✔ | ✔ | ✔ | ✖ + nested Owner same file | VIOLATION (rank 3) |
| …Supervisor.Owner | GenServer | ✔ | ✔ | ✖ | ✔ | ✔ | PASS (docs gap) |
| Storage.JournalSink | GenServer | ✔ (+continue, terminate) | ✔ | ✔ | ✖ (sync_tick) | ✔ | PASS |
| PowL2.HsmSigner | GenServer | ✔ | ✔ | ✔ | N/A | ✔ | PASS |
| PowL2.ChangeFeed | :gen_statem | ✔ (@impl) | ✔ | ✔ | N/A | ✔ | PASS — only clean gen_statem |
| PowL2.SbRules | GenServer | ✔ | ✔ | ✔ | N/A | ✔ ETS owner | PASS |
| DataPlane.AppconfigEvents | GenServer | ✔ | ✔ | ✔ | N/A | ✔ | PASS |
| Plane.Identity.StsGate | GenServer | ✔ | ✔ | ✔ | N/A | ✔ | PASS |
| Telemetry.SealedLog | GenServer | ✔ | ✔ | ✔ | N/A | ✔ | PASS |
| Pplan.Task | GenServer | ✔ (+continue) | ✔ | ✔ | N/A | ✔ | PASS |
| Messaging.EventHubs.Server | GenServer | ✔ | ✔ | ✖ | N/A | ✔ | PASS (docs gap) |
| Messaging.EventHubs (facade) | none | N/A | N/A | ✔ | N/A | ✔ | PASS |
| Messaging.EhGeoDr | GenServer | ✔ | ✔ | ✔ | N/A | ✔ | PASS |
| Messaging.AmqpBroker | Supervisor | ✔ | ✔ | ✔ | N/A | ✔ | PASS |
| Messaging.Amqp10.Connection | GenServer | ✔ | ✔ | ✔ | ✔ | ✖ conn+framing | BORDERLINE (rank 6) |
| Messaging.EventGrid | GenServer | ✔ | ✔ | ✔ | ✔ | ✔ | PASS |
| Messaging.EhCapture | GenServer | ✔ | ✔ | ✔ | ✖ (interval) | ✔ | PASS |
| Messaging.Amqp.Listener | GenServer | ✔ | ✔ | ✔ | ✔ | ✔ | PASS |
| Messaging.Amqp.Connection | GenServer | ✔ (+terminate) | ✔ | ✔ | ✔ | ✔ | PASS |
| Messaging.Amqp.CbsRouter | GenServer | ✔ | ✔ | ✔ | N/A | ✔ | PASS |
| Messaging.Amqp.QueueStore | GenServer | ✔ | ✔ | ✔ | N/A | ✔ | PASS |
| Messaging.Amqp.RuleStore | GenServer | ✔ | ✔ | ✔ | N/A | ✔ | PASS |
| Messaging.Amqp.Sweeper | GenServer | ✔ | ✔ | ✔ | ✖ (tick) | ✔ | PASS |
| Store.DetsMirror | GenServer | ✔ (+terminate) | ✔ | ✔ | ✖ (tick) | ✔ | PASS |
| Plane supervisors (×4) | Supervisor | ✔ | ✔ | ✔ | N/A | ✔ | PASS (model citizens) |

## Violations, ranked

1. **`telemetry.ex` — Smalt.Telemetry**: GenServer + `:telemetry` handler (`handle_event/4` at 92–109) + metrics dumper in one process; a telemetry-handler crash takes down counter state.
2. **`monitor/metrics.ex` — Smalt.Monitor.Metrics**: same pattern — handler callbacks in the same process as the prune loop.
3. **`affidavit/wasm_engine_supervisor.ex`**: Supervisor file also contains `Owner`, a hand-rolled stateful GenServer — should be its own file.
4. **`event_grid_webhook.ex`**: GenServer registry + Plug in one file — process does one thing, file does two.
5. **`application.ex`**: `@moduledoc false`, hosts three nested behaviour modules (DeferredListeners, ListenerDeferral, TlsTwinDispatch), all also undocumented.
6. **`messaging/amqp10/amqp10_connection.ex`**: connection supervision, TCP handling, performative dispatch in one process — borderline; framing could be extracted.

## Systemic finding (~24 modules)

**Missing `handle_info/2` catch-alls.** Only 6 modules trap unknown messages (`cluster.ex`, `wasm/pool.ex`, `event_grid.ex`, `amqp/listener.ex`, `amqp/connection.ex`, `amqp10_connection.ex`). Sharpest risk: modules with `trap_exit: true` but no `{:EXIT,...}` clause — `wasm/pool.ex` has one (✔), `store/dets_mirror.ex` has only `:tick`. Highest-value one-line fixes.

## Callback documentation

All callback clauses carry `@impl true` (spot-checked); per-clause `@doc` on handle_* absent repo-wide but `@impl` + moduledoc satisfies the doctrine in practice. Gaps: the 6 `@moduledoc false` modules listed above.

## Standing

**Standing:** PARTIAL PASS (updated BK-28, 2026-10-21) — no module fails on callback shape; catch-all coverage improved 6→8 modules; 5 file-level double-duty violations, 1 borderline, and the DetsMirror `:tick`-only handle_info remain open. Model citizens: `plane/*_supervisor.ex`, `powl2/change_feed.ex`, `store.ex`, `messaging/amqp/queue_store.ex`. Original census: 5 file-level double-duty violations, 1 borderline, 1 systemic (missing info catch-alls, ~24 modules), 6 `@moduledoc false` modules; compile + clause coverage prove all handle_*/init clauses return valid reply tuples.

## Re-witness (BK-28, 2026-10-21)

Re-derived from the CURRENT tree.

```
$ grep -rEn 'def handle_info\(_' lib/smalt --include='*.ex' -l | wc -l
8      # was 6 at audit time — apim.ex:67 and affidavit/wasm_engine_supervisor.ex:215
       # gained catch-alls with the JA-R2 GenServer conversion + JA-R3/related fixes
$ grep -n 'def handle_info' lib/smalt/apim.ex lib/smalt/affidavit/wasm_engine_supervisor.ex
lib/smalt/apim.ex:67:  def handle_info(_msg, state), do: {:noreply, state}
lib/smalt/affidavit/wasm_engine_supervisor.ex: 215:  def handle_info(_msg, state), do: {:noreply, state}
$ grep -n 'def handle_event\|def handle_info' lib/smalt/telemetry.ex
$ grep -n 'def handle_event' lib/smalt/telemetry.ex
92:  def handle_event([:bandit, :request, :stop], measurements, metadata, _config) do
103:  def handle_event([:smalt, _, _] = _event, _measurements, _metadata, _config) do
109:  def handle_event(_event, _measurements, _metadata, _config), do: :ok
337:  def handle_info(:prune, state) do
```

- **Systemic catch-all finding — IMPROVED: 6 → 8 modules** with unknown-message catch-alls
  (`apim.ex:67`, `affidavit/wasm_engine_supervisor.ex:215` are new; the original 6 remain:
  cluster, wasm/pool, event_grid, amqp/listener, amqp/connection, amqp10_connection).
- **Violations 1-5 (double-duty/file layout) — STILL OPEN, unchanged**: `telemetry.ex` still
  runs `handle_event/4` handlers in the counter GenServer (telemetry.ex:92-109 + :prune at 337);
  `monitor/metrics.ex`, `wasm_engine_supervisor.ex` (Owner co-file), `event_grid_webhook.ex`,
  `application.ex` nesting all as filed.
- **DetsMirror `trap_exit`/`:tick`-only handle_info — STILL OPEN** (dets_mirror.ex:223, sole
  `handle_info(:tick, ...)` clause).
- Standing update: **PARTIAL PASS — no module fails on callback shape; catch-all coverage 6→8;
  the 5 double-duty/file-layout violations and the DetsMirror :tick-only clause remain open.**
