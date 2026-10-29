# JA-8 Concurrency Purity Audit — lib/smalt

Repo: `/Users/sac/smalt` · Branch: `main` · Date: 2026-10-21 · Context: solo
Method: exhaustive grep of `Process.put/get`, `:erlang.put/get`, `persistent_term.put/erase`, `send/!` state-pokes, `Agent.*`, `Application.put_env`, GenServer call-density; read of every hit site. READ-ONLY agent; parent persisted.

## (1) Process dictionary for cross-call state

| Verdict | Site | Notes |
|---|---|---|
| LAWFUL (call-scoped, documented) | `lib/smalt/json_compat.ex:129-142,165,182,189,253,286` | Only pdict use in lib/smalt (9 write sites, one module). Stream state rides pdict strictly inside `stream/3`, initialized before and nil-ed in an `after` block; comment at :127-129 documents the caller-process execution model. Not cross-call state. |
| LAWFUL | whole repo | No `Agent.start_link`/`Agent.get`/`Agent.update` anywhere in lib/smalt — no hidden mutable state via captured refs. Closures capture ETS table names (immutable atoms) or pids they message (`hw/virtual_serial.ex:166-206`) — pure message passing. |

## (2) `:persistent_term` writes — hot-path census

18 write/erase sites:

| Verdict | Site | Frequency |
|---|---|---|
| LAWFUL — once-per-VM init | `auth/sts_key.ex:174,259` (under `:global.trans`), `security/receipt_signer.ex:162`, `trust_profile/trust_profile.ex:792`, `data_plane/skr.ex:307`, `apim.ex:52` | one write per VM lifetime |
| LAWFUL — boot/init only | `telemetry.ex:279`, `arm_gateway/lro_sweeper.ex:250` | once per boot |
| LAWFUL — mtime-gated | `auth/x_arr_cert.ex:133` | writes only on CA file mtime change; request path is a read |
| LAWFUL — memoized load boolean | `arm_gateway/router.ex:3311` (`finops_loaded?`) | put fires once |
| LAWFUL — log-once | `messaging/amqp/listener.ex:212-214` | once per key, ever |
| BORDERLINE | `messaging/amqp/atom_bridge.ex:127` (`rate_limited_reason/1`) | Write on the connection error path, every 5s window per distinct error atom. Key is an existing atom (no atom minting, :115-118), so write count is bounded by the atom table, not attacker input — but an adversarial peer cycling N distinct error reasons could force N global scheduler syncs inside windows. Recommend: move the window map to a `write_concurrency` ETS table. Flag, don't block. |
| LAWFUL — bounded, cold | `auth/bearer.ex:87` (per NEW trusted authority, capped, per-key), `:112` erase (test/restart only), `affidavit/wasm_engine.ex:148,56` (cold path) | bounded by config, not requests |

**No unlawful hot-path `persistent_term.put` found** (per-request writes: zero).

## (3) Direct process-state mutation pokes

None found. No `! {put_state`/`send(pid, {put...` patterns. All bare `send(pid, ...)` sites carry event payloads: `hw/virtual_serial.ex` (`{:hw_chunk,...}`, `{:hw_eof,...}`), `event_grid_webhook.ex:228`, `lro_notifier.ex:241`, self-scheduled ticks. State changes go through `GenServer.call/cast` (e.g. `lro_sweeper.ex` `{:flip_due, key}` cast).

## (4) Undeliberate single-process funnels

Store funnel is deliberate (JA-6, out of scope). Survey of the 33 GenServers:

| Verdict | Site | Notes |
|---|---|---|
| LAWFUL — not a funnel | `telemetry.ex` | rolling counters live in a **public ETS table** (`:smalt_rolling_counters`, `write_concurrency: :auto`); the GenServer only serves rollups |
| LAWFUL — not a funnel | `messaging/amqp/lock_manager.ex` | ETS-backed; no serialize-on-call path |
| BORDERLINE funnel | `messaging/amqp/cbs_router.ex:101-131` | every CBS `put_token`/`delete_token`/`authorized?` is a call to one process — serializes SAS token auth across all AMQP connections. Bounded by token lifetime, not per-frame; flag for JA-6 follow-up if token churn rises |
| BORDERLINE funnel | `event_grid_webhook.ex:104-124`, `data_plane/appconfig_events.ex:125-140` | subscriber registry + per-delivery `{:record,...}` call through one process; demo/edge-scale volume, undocumented as deliberate |
| LAWFUL | remaining GenServers | single-writer-by-design with in-source rationale (`wasm/pool.ex`, `lro_sweeper/notifier`, `cluster.ex`, `monitor/metrics.ex`, `powl2/*`, `journal_sink.ex`, sealing) |

## Standing

**Standing:** PASS with 3 footnotes, updated BK-28 (2026-10-21): 1 footnote resolved by JA-R2 (atom_bridge pterm→ETS), 2 borderline funnels remain. Zero pdict violations beyond documented call-scoped `json_compat` stream keys; zero unlawful hot-path `persistent_term` writes (1 borderline: `atom_bridge.ex:127` — recommend ETS migration); zero state-poke hacks; 3 borderline single-process serializations (`cbs_router`, `event_grid_webhook` registry/record, `appconfig_events`) that are lawful message-passing but undocumented as deliberate funnels. No code changes required to hold the JA model.

## Re-witness (BK-28, 2026-10-21)

Re-derived from the CURRENT tree. Fix authority: `ja-r2-apim-atom-bridge-fixes.md` (pterm→ETS
migration, standing ALIVE).

```
$ grep -n 'persistent_term\|:ets' lib/smalt/messaging/amqp/atom_bridge.ex
117:  # (no global scheduler sync per write, unlike :persistent_term). Creator is
129:    case :ets.lookup(@rate_limit_table, reason) do
134:        :ets.insert(@rate_limit_table, {reason, now})
140:    case :ets.whereis(@rate_limit_table) do
143:          :ets.new(@rate_limit_table, [
```

- **atom_bridge `persistent_term` borderline (§2, atom_bridge.ex:127) — FIXED (JA-R2)**:
  `lib/smalt/messaging/amqp/atom_bridge.ex:117-143` is now `write_concurrency: true` ETS
  (`:ets.lookup`/`:ets.insert` bounded by the existing atom key set, no global scheduler sync
  per write). The one BORDERLINE `persistent_term` write is gone.
- **pdict (§1), state-pokes (§3), cbs_router/event_grid/appconfig_events funnels (§4) — STILL
  OPEN, unchanged** (documented borderline funnels remain as filed).
- Standing update: **PASS — of the 3 footnotes, 1 resolved by JA-R2 (atom_bridge pterm→ETS);
  pdict/poke laws still hold; 2 borderline funnels (cbs_router, event_grid_webhook/appconfig_events
  registry) remain as documented borderlines.**
