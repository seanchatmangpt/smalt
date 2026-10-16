# AtomVM Bridge (lib/atomvm)

Erlang-style actor semantics for the constellation simulator, with a hard mode
boundary between a real AtomVM WASM runtime and a pure-TypeScript simulation.

## Files

- `etf.ts` — External Term Format encoder/decoder. Pure TS, zero dependencies.
  Terms: integers (incl. bignums), binaries (`Uint8Array`), atoms (`{atom}`),
  lists (`{list}`), tuples (`{elements}`), maps (`{map: [[k,v],...]}`).
  Decode is bounded and strict: max 4 MiB per term (`ETF_MAX_INPUT_BYTES`),
  max depth 64, refuses improper lists, trailing bytes, and unknown tags.
- `actor-host.ts` — `ActorHost`: `spawn`, `send(pid,msg)`, `call(pid,msg)`,
  `stop`. Loads an `.avm` bundle if present; otherwise runs in SIMULATION mode.
- `constellation-actors.ts` — `ConstellationNode` per-asset state machine:
  thermal budget (first-order lag to 288 K), battery reserve, bounded ephemeris
  table. Deterministic and event-sourced: every transition emits an event, state
  is the fold of events from `INIT`. Fixed-point integer arithmetic ONLY — all
  quantities are integers in milli-units (mK, mAh, meters). No floats anywhere.
- `atomvm.avm` — (optional) AtomVM WASM bundle. NEVER fabricated or committed
  as a stub. Presence is detected by the `FOR1` magic header.

## Actor contract (identical in both modes)

```ts
const host = new ActorHost();          // auto: wasm if atomvm.avm loads
const pid  = host.spawnConstellation('SAT-042');

host.send(pid, { elements: [atom('tick'), 60000] });   // cast: enqueues only
host.dispatch(pid);                                     // run a scheduling turn
const snap = host.call(pid, { elements: [atom('query')] }); // call: enqueue + turn
// snap = #{ asset => <<"SAT-042">>, t_ms => 60000,
//          thermal_mK => ..., battery_mAh => ..., drops => 0, ... }
```

Message tuples (the wire contract, ETF-encoded):

| Message | Shape | Reply |
|---|---|---|
| tick | `{tick, Tms}` | `ok` \| `monotonic_violation` |
| set_ephemeris | `{set_ephemeris, [{Tms,Xm,Ym,Zm},...]}` | `ok` (table capped at 256, newest kept) |
| set_power | `{set_power, MAh}` | `ok` |
| query | `{query}` | map snapshot of state |

Helpers: `msgToEtf` / `msgFromEtf` in `constellation-actors.ts`.

## Mode boundary

| | WASM mode | SIMULATION mode |
|---|---|---|
| Trigger | valid `.avm` bundle at `lib/atomvm/atomvm.avm` | bundle absent |
| Executor | BEAM inside AtomVM WASM | same behavior code in TS |
| Transport | ETF bytes across the wasm boundary | ETF terms in-process |
| Pid node | `avm@wasm` | `sim@ts` |
| Opt-in | `new ActorHost({mode:'wasm'})` (throws if no bundle) | default |

There is no behavioral fork: the TS actor module defines the contract; the .avm
is a different executor of the same messages. Swapping in a real build:

1. Build AtomVM with WASM target and your BEAM modules compiled into a bundle:
   `atomvm_toolchain packbeam assets.avm my_node.beam ...` (see AtomVM docs).
2. Place the result at `lib/atomvm/atomvm.avm` (path override:
   `new ActorHost({bundlePath})`).
3. The host validates the `FOR1` header; a file that fails validation throws —
   it never silently falls back to simulation.
4. `host.mode` tells you which executor is live; log it at startup.

## Memory discipline (< 32 MB heap budget)

- ETF decode refuses inputs > 4 MiB before allocating (`ETF_MAX_INPUT_BYTES`);
  nesting depth capped at 64; collection arity capped at 65536.
- Mailboxes are bounded (default 64, `mailboxCapacity` option). Overflow policy:
  **drop-oldest**, and every eviction increments a counter. `send` enqueues only;
  `dispatch(pid)` runs a scheduling turn, so a burst of sends against a full
  mailbox visibly drops (counter observable via `listActors()`; the state field
  `dropsObserved` + `applyDrops()` exist for consumers that fold it into the
  event stream). `call` on a full mailbox returns
  `{atom: 'mailbox_full'}` instead of blocking.
- Per-actor event log capped at 256 events; evicted events are counted in
  `eventsRetired` (conservation: nothing disappears uncounted).
- Ephemeris table capped at 256 points (newest kept).
- Actor state is integers and bounded arrays only — no unbounded growth, no
  closures or large objects retained between turns.

## Determinism guarantees

- No wall clock, no randomness; time advances only via `tick` messages.
- Monotonic-time guard: a `tick` to an earlier `t_ms` replies
  `monotonic_violation` and leaves state untouched.
- Same message sequence => same state => same ETF reply bytes, in either mode.
