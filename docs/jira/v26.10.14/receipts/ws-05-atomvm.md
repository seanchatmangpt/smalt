# WS-05 Receipt — AtomVM WebAssembly Bridge

- **Date**: 2026-10-15
- **Lane**: WS-5
- **Subject**: `workspace/lib/atomvm/{etf.ts, actor-host.ts, constellation-actors.ts, README.md}` @ smalt `main` (3fc2543, uncommitted working tree)
- **Standing**: ALIVE (simulation mode) / UNKNOWN (wasm mode — no `.avm` bundle exists; none was fabricated)

## Delivered

| File | Content |
|---|---|
| `workspace/lib/atomvm/etf.ts` | ETF (v131) encoder/decoder, pure TS, zero deps. Ints (SMALL_INTEGER/INTEGER/SMALL_BIG/LARGE_BIG), binaries, atoms (SMALL_ATOM_UTF8, reads ATOM_UTF8/ATOM latin-1), lists, tuples, maps. Decode bounded: 4 MiB input cap, depth 64, arity 65536; refuses bad version, truncation, trailing bytes, improper tails, unknown tags. |
| `workspace/lib/atomvm/actor-host.ts` | `ActorHost`: spawn/send/dispatch/call/stop, identical API in both modes. Loads `.avm` only if present at `lib/atomvm/atomvm.avm`, validates `FOR1` magic, never fabricates; absent bundle -> SIMULATION. Bounded mailboxes (default 64), drop-oldest + counter. |
| `workspace/lib/atomvm/constellation-actors.ts` | ConstellationNode behavior: thermal budget (first-order lag to 288 K), battery reserve, bounded ephemeris (cap 256). Deterministic, event-sourced (TICK/EPHEMERIS_SET/INIT/DROPS events, `eventsRetired` conservation counter), fixed-point integers only (milli-units). Wire contract `msgToEtf`/`msgFromEtf` over ETF tuples. |
| `workspace/lib/atomvm/README.md` | Wasm contract, mode boundary table, swap-in procedure for a real AtomVM build, memory discipline. |

## Actor contract (identical in both modes)

- `host.spawn(behavior)` / `host.spawnConstellation(assetId)` -> `Pid`
- `host.send(pid, msg: EtfTerm)` -> `'ok' | 'dropped'` (enqueue only)
- `host.dispatch(pid)` — run one scheduling turn to quiescence
- `host.call(pid, msg)` -> `EtfTerm | undefined` (enqueue + turn; full mailbox -> `{atom:'mailbox_full'}`, never blocks)
- Messages: `{tick,Tms}` `{set_ephemeris,[{Tms,X,Y,Z},...]}` `{set_power,MAh}` `{query}`; `msgToEtf`/`msgFromEtf` are the wire codecs.

## Mode boundary

WASM mode requires a valid `.avm` (FOR1 header) at `lib/atomvm/atomvm.avm`
(explicit `mode:'wasm'` with no bundle throws); otherwise SIMULATION with the
same behavior code and message contract. The TS behavior IS the contract; the
.avm is a different executor of the same ETF messages. Node names: `avm@wasm`
vs `sim@ts`. No .avm bundle exists in the tree — wasm-mode execution is UNKNOWN.

## Verification (actual output)

1. `tsc --ignoreConfig --noEmit --strict --noUnusedLocals --noUnusedParameters ...` over the three TS files -> **TSC_CLEAN** (exit 0).
2. Executed smoke run (`npx tsx`, real process):
   - ETF round-trip of nested tuple/list/map/binary/bigint/negative-int: `roundtrip_ok true`
   - bigint: `etfEncode(1000n)` -> `[131,110,2,0,232,3]` -> decode -> `bigint 1000` (verified in isolated run; J() JSON artifact in batch run only)
   - Refusals: `bad_version_refused ETF_VERSION`, `truncated_refused ETF_TRUNCATED`
   - `mode simulation`, query snapshot shows t_ms 60000, thermal 288450 mK, battery 119880 mAh, events 2
   - Determinism: same message sequence -> byte-identical snapshot: `deterministic true`
   - Monotonic guard: earlier `tick` -> `monotonic_violation`, state untouched
   - Mailbox: capacity 1, 3-send burst -> `dropped: 1`, then `ok` with drop-oldest (final state t_ms=30 proves oldest evicted), counter observable via `listActors()`

## Defects found and fixed during execution

1. Bignum decode read the sign byte at magnitude-end while encode wrote sign-first (ETF spec order Sign,d0..dn-1) — caught by the run, fixed, rerun clean.
2. Mailbox drop-oldest was unreachable: `send` drained synchronously so the queue never filled — `send` is now enqueue-only with explicit `dispatch(pid)` turn; drop path executed and counted for real.

## Notes / handoff

- `tsc --noEmit` run with `--ignoreConfig` because WS-1's workspace `tsconfig.json` landed mid-session; my lane files were verified strictly and independently of it.
- WS-5 touched ONLY `workspace/lib/atomvm/*` + this receipt.
