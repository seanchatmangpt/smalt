# Workspace Lanes (WS-01..WS-12) — v26.10.14

Index of the 12-lane workspace fan-out over `workspace/`
(the Next.js sovereign console). Release work orders and the 20-lane smalt
fan-out live one level up; this index covers the workspace lanes only.
Receipts: `../receipts/ws-*.md`.

| Lane | Surface | Files (workspace-relative) | Receipt |
|---|---|---|---|
| WS-01 | Scaffold: Next.js app + shared config | `package.json`, `tsconfig.json`, `app/` | — |
| WS-02 | Sovereign Hierarchy Navigator | `lib/navigator/{tree-model,fixtures}.ts`, `components/navigator/*` | [ws-02-navigator](../receipts/ws-02-navigator.md) |
| WS-03 | Inspector (Hex/JSON/Attestation modes) | `lib/inspector/encoding.ts`, `components/inspector/*` | [ws-03-inspector](../receipts/ws-03-inspector.md) |
| WS-04 | Zero-actuation Copilot | `lib/copilot/{verb-gate,typed-refusal,session-ledger}.ts`, `components/copilot/*` | [ws-04-copilot](../receipts/ws-04-copilot.md) |
| WS-05 | Azure Sovereign clients | `lib/azure/*` | — |
| WS-06 | Web Serial gateway | `lib/serial/*` | [ws-06-serial](../receipts/ws-06-serial.md) |
| WS-07 | Dynamic Bellman Solver | `lib/solver/*` | [ws-07-solver](../receipts/ws-07-solver.md) |
| WS-08 | AtomVM substrate + ETF codec | `lib/atomvm/*` | — |
| WS-09 | Messaging telemetry (SB/EH probes) | `lib/azure/{sb-telemetry,eh-stream}.ts` | — |
| WS-10 | Attestation validator | `lib/attestation/*` | [ws-10-attestation](../receipts/ws-10-attestation.md) |
| WS-11 | Compliance (AU-10) | `lib/compliance/*` | [ws-11-compliance](../receipts/ws-11-compliance.md) |
| WS-12 | E2E court + architecture landing | `scripts/e2e-court.mjs`, `ARCHITECTURE.md`, this index | [ws-12-e2e](../receipts/ws-12-e2e.md) |
| (coord) | Fan-out governance | `docs/jira/v26.10.14/_LANES.md` | — |

## Court status (as of 2026-10-15, ws-12 court run)

- `node scripts/e2e-court.mjs` — PASS=33 FAIL=6 SKIP=2, exit 1.
- All WS-12 targeted checks PASS (CRC-16 vector 0x29B1, ETF small terms,
  Bellman determinism, JCS ordering, verb-gate refuse/pass, attestation
  trio, ledger chain + guardedFetch refusal, serial frame codec).
- Open FAILs are owned by their lanes, not the court: ETF bignum decoder
  sign-byte offset (WS-08), `@azure/*` runtime deps absent for arm-client /
  resource-queries / eh-stream (WS-05/09), `validator.ts` `.ts`-extension
  imports breaking compiled requires (WS-10), azure type errors in the
  strict type-surface check (WS-05/09).
