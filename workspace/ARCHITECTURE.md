# Workspace Architecture (C4) — smalt Sovereign Console

## Context

The smalt Sovereign Console is an air-gapped, zero-actuation evaluation console for
Fortune-5 sovereign-cloud evaluation of the smalt substrate. It runs as a Next.js
workspace at `workspace/` inside the smalt repo. Its only permitted
network host is the local smalt emulator: ARM control plane on `http://127.0.0.1:9443`,
the ARM TLS twin on `https://127.0.0.1:9444` (real Azure SDK legs ride TLS),
egress planes on `http://127.0.0.1:8443` (blob/Cosmos docs), AMQP lanes on
`127.0.0.1:5672` (Service Bus) and `127.0.0.1:5673` (Event Hubs). No WAN egress; the
console is read-only by construction.

Zero-actuation and the air-gap are enforced at three layers: (1) the client
fetch wrapper (`lib/smalt.ts` `smaltFetch`/`assertLocalUrl`), (2) the server
air-gap layer (`src/lib/airgap-fetch.ts` `airgapFetch` + `middleware.ts`
request-level enforcement; loopback-only hosts, ports 9443/9444/8443), and
(3) the mutation-verb gate (`lib/copilot/verb-gate.ts`,
`lib/copilot/session-ledger.ts`): any request whose method+URL matches a mutation
pattern never reaches the network — a typed refusal (`lib/copilot/typed-refusal.ts`)
is appended to the hash-chained session ledger (`appendRefusal` → FNV-1a hash chain)
and returned to the caller. Reads pass through `guardedFetch`.

Hardware trust anchors to a Web Serial device: the console talks to a secure element
over a framed serial protocol (115200 8N1, `[0x7E][len:u16 LE][payload][crc16:u16 LE][0x7E]`,
byte-stuffing 0x7D escape, CRC-16/CCITT-FALSE). Device identity (chipset serial +
boot measurement) is checked against the boot-digest allowlist; receipts are JCS
canonical-JSON signed (RFC 8785 subset in `lib/attestation/canonical.ts`) and validated
by `lib/attestation/validator.ts` (RS256 / ECDSA-P256 via WebCrypto).

The Dynamic Bellman Solver (`lib/solver/bellman.ts`, `lib/solver/policy.ts`) schedules
sensor tasking over a reachability DAG in fixed-point integers (SCALE=10_000), so
solver output is bit-for-bit deterministic across runs and platforms — the console
never floats in the math path.

The Azure Sovereign export path is one-way: session-ledger receipt bundles export to
the emulator's immutable (WORM) blob container via
`lib/azure/blob-export.ts` — the second write of the same blob is rejected 409, and
that rejection IS the diode guarantee (nothing can rewrite an exported receipt).
Mission manifests ride the Cosmos docs engine (`SELECT * FROM c` only, client-side
filtering); mission telemetry rides the Service Bus lane; Event Hubs is PARTIAL
(receiver delivery witnessed as dead code in the substrate — see
`smalt docs/WIRE_PARITY.md` EH section).

AtomVM runs the on-device BEAM on wasm+silicon substrate; the console models it as
wasm module lifecycle (`not-loaded/loading/running/faulted` in `lib/types.ts`), the
ETF codec (`lib/atomvm/etf.ts`) encodes/decodes Erlang External Term Format terms,
and actor-host/constellation-actors model the on-device actor surface.

## Containers

```text
+--------------------------------------------------------------+
|  Next.js console (browser)                                    |
|  app/layout.tsx + app/page.tsx → 3-panel layout               |
|    +-------------------------------+------------------------+ |
|    | TreeNavigator (left)          | ResourceInspector      | |
|    | 150k-node sovereign hierarchy |  (right)               | |
|    | tree-model / fixtures         |  Hex/JSON/Attestation  | |
|    |          +--------------------+ modes; encoding.ts     | |
|    |          | CopilotPanel (bottom)                       | |
|    |          | verb-gate + typed refusal + ledger          | |
|    +-------------------------------+------------------------+ |
+------------------+---------------------------+---------------+
                   |                           |
     Web Serial    |                           | fetch (GET-only by gate)
     115200 8N1    |                           |
        +-----------+--------+      +-----------+------------+
        | Secure element     |      | smalt local substrate  |
        | (AtomVM wasm+      |      | ARM :9443              |
        |  silicon)          |      | TLS twin :9444 (SDKs)  |
        | ETF over framed    |      | egress :8443 (blob/    |
        | serial protocol    |      |  cosmos docs, WORM)    |
        | boot-digest        |      | AMQP 5672 (SB)         |
        | allowlist          |      | AMQP 5673 (EH, PARTIAL)|
        +--------------------+      +------------------------+
```

Containers diagram (text C4 L2). L3 component detail follows.

## Components

- **Navigator** — `components/navigator/{TreeNavigator,TreeNode}.tsx`,
  `lib/navigator/{tree-model,fixtures}.ts`: read-only projection, lazy
  children memoized in a WeakMap, depth-first `flattenVisible` for virtualized
  rendering, typeahead over labels, 150k-scale seeded fixture.
- **Inspector** — `components/inspector/*.tsx`, `lib/inspector/encoding.ts`:
  Hex/JSON/Attestation tabs. Safe rendering: invalid UTF-8 → U+FFFD, control
  bytes → `.`, ETF envelope (magic 131) recognized (full decode owned by the
  ETF codec). Attestation mode renders receipt validation verdicts.
- **Copilot** — `components/copilot/CopilotPanel.tsx`,
  `lib/copilot/{verb-gate,typed-refusal,session-ledger}.ts`: mutation-verb
  interceptor at the suggestion layer and the fetch wrapper; refusals are
  receipts (identity verb+url, consequence reason, ts), ledgered on an
  append-only FNV-1a hash chain with `verifyLedgerChain`.
- **Serial gateway** — `lib/serial/{protocol,gateway,gateway-events}.ts`:
  frame codec + streaming `FrameDecoder` with resync, typed request/response
  exchange, SSR-safe (UNSUPPORTED envelope when `navigator.serial` is absent).
  Envelope vocabulary `OK | UNSUPPORTED | NOT_CONNECTED | IO_ERROR | BAD_FRAME | TIMEOUT`.
- **Solver** — `lib/solver/{bellman,policy,fixtures}.ts`: exact backward
  induction, fixed-point SCALE=10_000, lowest-action-index tie-break, O(H)
  policy replay, seeded mulberry32 fixtures.
- **Attestation** — `lib/attestation/{canonical,boot-digests,validator}.ts`:
  JCS (RFC 8785 subset) canonical JSON for the signing input, boot-measurement
  allowlist per chipset serial, total `verify()` with
  `ALGORITHM_UNSUPPORTED` typed refusal for unknown algorithms.
- **AtomVM** — `lib/atomvm/{etf,actor-host,constellation-actors}.ts`: ETF
  encode/decode (integers, bignums, binaries, atoms, lists, tuples, maps),
  actor-host and constellation actor surface for the wasm+silicon substrate.
- **Azure Sovereign** — `lib/azure/*`: WORM receipt export (409-on-overwrite as
  the one-way diode), Cosmos mission-manifest store (`SELECT * FROM c` only),
  Service Bus telemetry send/receive probes, Event Hubs PARTIAL lane probe,
  ARM client + token credential + read-only resource queries.
- **Compliance** — `lib/compliance/{au10,ledger-types}.ts`: AU-10 evidence
  surface and ledger vocabulary for compliance export.

## Operations

- Court: `node scripts/e2e-court.mjs` — unit-import sweep + targeted checks
  (CRC-16 vector, ETF round-trip, Bellman determinism, JCS ordering, verb-gate
  refuse/pass, attestation trio, ledger chain + guardedFetch, frame codec) +
  component type-surface (tsc --strict --noEmit) + optional live ARM probe
  (SKIP when the substrate is down). Exit 0 only with zero FAILs.
- Court verdict as of 2026-10-18: PASS=51 FAIL=0 SKIP=1 (`just ws-court` or
  `node workspace/scripts/e2e-court.mjs`; the SKIP is the node-inexecutable
  DOM/Web Serial panel rendering, witnessed at the type layer instead).

## Cost

Cost analysis: see the enterprise assessment cost table (not reproduced here) —
link-note: `docs/jira/v26.10.14/ws/README.md`.
