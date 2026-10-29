# JA-1 Supervision Census — smalt @ main (2026-10-21)

Context: solo

Joe Armstrong's DoD #1: every process has a supervisor; restart strategy typed and intentional.

## Tree (from `lib/smalt/application.ex`, `Smalt.Supervisor`, strategy `:one_for_one`, default intensity 3/5s)

```
Smalt.Supervisor (one_for_one)
├─ Smalt.Plane.DataSupervisor (one_for_one, max 5/5s)
│   ├─ Smalt.Store                        (GenServer, permanent, named)
│   └─ Bandit (EgressRouter :8443)        (worker, shutdown 10_000)
├─ Smalt.Plane.ControlSupervisor (one_for_one, max 5/5s)
│   ├─ Smalt.Store (only on non-data plane boots, GAP-AZB20-1/4)
│   ├─ Bandit (ArmGateway.Router :9443)   (shutdown 10_000)
│   ├─ Smalt.ArmGateway.LRO.Notifier      (GenServer)
│   ├─ Smalt.ArmGateway.LRO.Sweeper       (GenServer, crash-restart is the documented signal)
│   ├─ Smalt.Affidavit.WasmEngine.Supervisor (one_for_one, max 3/1s)
│   │   └─ Supervisor.Owner               (GenServer, restart: :permanent, own-mailbox retry/backoff)
│   └─ Bandit TLS twin :9444               (shutdown 10_000; deferred under :deferred_listeners)
├─ Smalt.Plane.IntegrationSupervisor (one_for_one, max 5/5s)
│   ├─ Smalt.Store (only on integration-only boots)
│   └─ Smalt.AmqpBroker (one_for_one)
│       ├─ Smalt.Amqp.Listener :sb :5672
│       ├─ Smalt.Messaging.EventHubs.Listener :eh :5673
│       ├─ Smalt.Amqp.Sweeper             (GenServer)
│       └─ Smalt.AmqpBroker.ConnSup       (DynamicSupervisor, one_for_one)
│           └─ Smalt.Amqp.Connection      (restart: :temporary — crash contained, listeners survive)
├─ Smalt.Plane.IdentitySupervisor (one_for_one, max 5/5s)
│   └─ Smalt.Plane.Identity.StsGate       (GenServer)
├─ Smalt.Apim                             (child_spec → spawn_link owner of rate-limit ETS)
├─ Smalt.Telemetry.RollingCounters        (GenServer)
├─ Smalt.Monitor.Metrics                  (GenServer, owns dedicated ETS)
├─ [deferred mode] DeferredListeners (one_for_one, empty) + ListenerDeferral (GenServer, self-terminates :shutdown after one tick)
├─ [deferred mode] Bandit MCP :9545       (into DeferredListeners / Smalt.Supervisor, shutdown 10_000)
└─ [SMALT_SIMULATE_HARDWARE=1] Smalt.Hw.VirtualSerial (GenServer)
└─ [:journal_sink_dir set] Smalt.Storage.JournalSink (GenServer)
```

## Findings by class

### SUPERVISED (strategy correct)
- All 5 named supervisors + DeferredListeners + WasmEngine.Supervisor + AmqpBroker + ConnSup: typed strategies, documented rationale (AZB-09 plane partitioning, AZB-22b bounded shutdown, crash-only AMQP containment).
- `Smalt.Amqp.Connection` (`restart: :temporary` under ConnSup) — per-connection crash containment is explicit and intentional.
- `Smalt.Affidavit.WasmEngine.Supervisor.Owner` — `restart: :permanent` with kill-hammer-safe own-mailbox retry that deliberately avoids consuming supervisor intensity.
- LRO Sweeper: crash→supervisor restart is the documented honest-failure signal.

### INTENTIONAL-UNSUPERVISED (justified)
- `Smalt.Amqp10` session/link/listener `spawn_link` family (`amqp10_connection.ex:48,236`, `amqp10_session.ex:14`, `amqp10_link.ex:23`) — linked to the Connection GenServer, which is `:temporary` under ConnSup; crash propagates up, connection recycled. Contained.
- `Smalt.Hw.VirtualSerial` reader `Task.start` (virtual_serial.ex:162,190) — short-lived I/O pump, EOF/error sent back to the owning GenServer; the GenServer is supervised.
- `Task.async` in `lib/mix/tasks/smalt.native_ladder.ex` and `lib/smalt/powl2/executor.ex` — caller-linked with await/timeout; caller is either the mix runner or a supervised path.
- Lazy-start GenServers (EventGridWebhook/QueueStore pattern): `Smalt.Messaging.EventGrid`, `Smalt.Messaging.EhCapture`, `Smalt.Messaging.EhGeoDr`, `Smalt.DataPlane.AppconfigEvents`, `Smalt.Amqp.QueueStore`, `Smalt.Amqp.RuleStore` — started by first caller; the pattern is disclosed in-code but the started process is linked to the caller, not a supervisor.

### UNSUPERVISED (violations, ranked)

1. **HIGH — `Smalt.Apim` rate-table owner** (`lib/smalt/apim.ex:47-54`). It IS a child of `Smalt.Supervisor`, but the child is a naked `spawn_link(fn -> ... Process.sleep(:infinity) end)` — not a GenServer/`proc_lib` process. An unmanaged spawn as a supervised child means: no `proc_lib` label on crash reports beyond the manual `set_label`, no trap-exit hygiene, and critically `child_spec` returns `{:ok, pid}` from `spawn_link` — a start **failure** (e.g. table create error) is silently swallowed unless the fn raises; the supervisor will restart it permanently (permanent default) forever on a persistent boot defect. Should be a `use GenServer` owner. Same defect class as the lazy-ETS silent-disarm law.
2. **HIGH — AMQP 1.0 settled-ledger holder** (`lib/smalt/messaging/amqp10/amqp10_connection.ex:236-244`). `spawn` (unlinked!) + `park()` receive loop holding `:smalt_amqp10_ledger` ETS. Unlinked means the holder survives all crashes — that is disclosed as intentional, but there is NO supervisor and NO restart if the holder itself dies ("next connection lazily re-creates the table" — i.e. ledger contents are lost silently on holder death, and the `spawn` return value is discarded, so a race can leave no holder at all while `wait_ledger` retries). Armstrong: this is an unsupervised stateful process.
3. **MEDIUM — `Smalt.Wasm.Pool`** (`lib/smalt/wasm/pool.ex`). 16 pre-warmed `Smalt.Wasm.Worker` GenServers (`restart: :temporary`) respawned via the pool GenServer's trap_exit/EXIT handling — but the **pool GenServer itself has no start site anywhere** (only `bridge.ex` references it; no child spec, no supervisor, no lazy-start shim). If it is ever started, it is started by a caller and dies with the caller. Dead code today, unsupervised-by-construction if wired.
4. **MEDIUM — `Smalt.Cluster`** (`lib/smalt/cluster.ex`). GenServer, config-gated (`enabled: true` raises at init if unset), polls DNS. **No start site in any supervisor or child spec**; only `cluster_status/0` reads. If enabled, it must be started by an embedder with no supervised home — no child_spec/child is wired anywhere in `lib/` or `config/`.
5. **LOW — lazy-start pattern** (EventGridWebhook family, 6 modules). First-caller-linked GenServers: the caller's death kills the "singleton". Disclosed in-code as a pattern, and `EventGrid`/`QueueStore`/`RuleStore` ship `restart: :permanent` child_specs "for embedder/azsim use" — but nothing in the app tree starts them, so under `Smalt` proper they are unsupervised at runtime.
6. **LOW — `Smalt.Apim` child_spec swallows start errors** (subsumed by #1): `spawn_link` never returns `{:error, _}`, so the one_for_one strategy types the restart but not the start.

## Standing

**Standing:** PARTIAL PASS — 1 of 6 findings fixed (JA-R2), 5 open. The 9 named supervisors are exemplary (typed, documented, bounded shutdowns, temporary/permanent restarts deliberate); the tree's spine passes Armstrong's test. Violation #1 (Apim naked `spawn_link`) is FIXED by JA-R2 — see Re-witness below. Open: the unlinked amqp10 settled-ledger holder `spawn` (amqp10_connection.ex:231), and `Wasm.Pool`/`Cluster` with no supervised home, plus the lazy-start family.

## Re-witness (BK-28, 2026-10-21)

Re-derived from the CURRENT tree. Fix authority: `ja-r2-apim-atom-bridge-fixes.md` (JA-1 #1 closed there, standing ALIVE, 21/21 tests).

```
$ grep -c 'spawn_link' lib/smalt/apim.ex
1                # the only hit is the JA-R2 comment at apim.ex:48 — zero live spawn_link
$ grep -n 'start_link\|handle_info(_' lib/smalt/apim.ex
59:  def start_link, do: start_link([])
63:  def start_link(_arg) do
67:    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
67:  def handle_info(_msg, state), do: {:noreply, state}   # (apim.ex:67 catch-all)
```

- **#1 Apim naked `spawn_link` owner — FIXED (JA-R2).** `lib/smalt/apim.ex:46-67` is now a proper
  `use GenServer` owner: `child_spec` + `start_link/1` → `GenServer.start_link(__MODULE__, :ok,
  name: __MODULE__)`; start failures surface as `{:error, _}` to the supervisor; init creates the
  rate table in the owner with `{:heir, Process.whereis(:init), []}` (ja-r2 receipt, 21/21 tests).
- **#2 amqp10 settled-ledger holder — STILL OPEN, unchanged.**
  `lib/smalt/messaging/amqp10/amqp10_connection.ex:231-237`: still `spawn(fn -> :proc_lib.set_label(...)
  ...; park() end)` — unlinked, return value discarded, `wait_ledger(100)` retry. No supervisor, no heir.
- **#3/#4 Wasm.Pool / Cluster — STILL OPEN.** No start site in `lib/smalt/application.ex` or any
  plane supervisor (grep for `Wasm.Pool`/`Smalt.Cluster` across `application.ex` + `lib/smalt/plane/*.ex`:
  only pool.ex's own `start_link`, pool.ex:17-18). Dead-code/unsupervised-by-construction as originally filed.
- **#5 lazy-start family — STILL OPEN, unchanged** (EventGridWebhook family, first-caller-linked).

Index effect: the receipt carried an explicit Standing line → no longer degrades to UNKNOWN; the
aggregate SUSPECT flag (no embedded command output) clears with this embedded output.
