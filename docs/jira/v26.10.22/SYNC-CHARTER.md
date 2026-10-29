# the law-input project — Four-Sovereign-Axiom Implementation Charter (operator, 2026-10-21)

Standing: OPERATOR-CHARTER — the engine already exists (smalt v26.10.21 / graphlaw 5dc3c01);
the law-input project is an INPUT (law files), not a codebase. The engineering delta is strictly mechanical.

## Iron rule

If a domain word (`bates`, `matter`, `privilege`, `order`) appears inside an `.erl`, `.ex`,
`.ts`, or `.tsx` file, the architecture is violated. Substrate code moves opaque bytes,
checks integer opcodes, enforces process boundaries. Domain semantics live ONLY in
`law/shacl.ttl` / `law/n3` / `law/powl.ttl`.

## Axiom layers

1. **Law (O\*)** — RDF/SHACL/N3/POWL `.ttl` files. Knows domain shapes; blind to hardware.
2. **Reticle (μ)** — `graphlaw.wasm` (ops: 1 SHACL preflight, 2 N3 admission, POWL compile,
   15 duckdb-over-sealed). Knows graph mechanics; blind to domain + network.
3. **Operational substrate** — Smalt (OTP 29) + browser client. Knows sockets/CAS/WAL
   append/packet-4 ports; blind to domain words and SQL.
4. **Storage horizon** — append-only `.wal` frames (`MAGIC|len|seq|ts|CRC32`) + `.seal`
   atomic rotation. Blind to payload meaning.

## Mechanical execution chain (all courted, receipts on disk)

Browser: raw bytes → governance sieve via graphlaw.wasm (0=admit/1=ANDON at byte 0) →
actor-state CAS → IndexedDB WAL append (SeqID+1, CRC32) → BLAKE3 Merkle accumulator.
Sync: un-acked frames + client Merkle root over Transport.Fetch (raw binary, no JSON).
Server: (1) frame integrity in pure Erlang — corrupt ⇒ kill the connection process;
(2) same graphlaw.wasm through the WASM-1 packet-4 pool (latin1 pinned, GWS-18 shim) —
cross-engine determinism (GWS-12) guarantees identical partition decisions;
(3) ANDON ⇒ Merkle refusal leaf, Store never touched; Admit ⇒ 5µs CAS + journal frame;
(4) 320-byte Merkle receipt returned, client marks frames synced.
Lakehouse: SJ-1 rotation (fsync→rename→meta.json→.seal) → GraphLaw/frozen-duckdb mounts
sealed segments read-only, same compiled predicate (GL-6), 450k rows/s measured.

## v26.10.22 work orders (mechanical delta only)

| WO | Deliverable | Gate |
|---|---|---|
| SYNC-1 | Server batch-frame receiver on the smalt wire gateway: integrity check (pure Erlang, kill-on-corrupt), WASM-1 sieve dispatch, CAS-or-ANDON commit, receipt frame return. Domain-blind. | corrupt-frame court (kill + tree standing); ANDON ⇒ zero Store mutation; admit ⇒ receipt round-trip |
| SYNC-2 | Next.js browser client (workspace/): graphlaw.wasm in a web worker (ops 1+2), IndexedDB WAL, BLAKE3 Merkle accumulator, batch sender via `smaltFetch` (the workspace's only sanctioned egress — this IS Transport.Fetch here). ESLint no-raw-fetch law holds. | end-to-end: local admit → sync → server admit → receipt marks frames synced; ANDON case drops at byte 0 |
| SYNC-3 | the law-input project law files (`law/shacl.ttl`, `law/n3`, `law/powl.ttl`) + GLD-7 ingest-to-settlement court run over them. | 0-byte refusal on ethical-wall breach; conformed Merkle sealing; law swap does not touch a single substrate line |
| (carried) | Kernel TTVs from the ARMSTRONG-PLAN (TTV-1/2/3 landed via JA-R3; TTV-4 landed; TTV-5, BK-33 rebind in flight) | see DIRECTIVES.md TTV ledger |

## Boundary notes (measured, not assumed)

- workspace/ networking: `lib/smalt.ts` `smaltFetch` + `assertLocalUrl` only; ESLint bans
  raw `fetch` literals — the batch sender must ride it (TLS twin 9444 for real-SDK legs).
- packet-4 stdio harnesses MUST set `:io.setopts(:standard_io, encoding: :latin1)` before
  the first frame (WASM-1 witness).
- graphlaw.wasm browser embedding: the pinned 14-op artifact (`priv/graphlaw.wasm`,
  blake3 `cbc80f07…`) is the subject; duckdb op-15 is native-side only (BLOCKED on wasm32
  frozen-duckdb) — the lakehouse leg stays server-side by decision.
