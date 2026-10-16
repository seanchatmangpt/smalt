# lib/compliance (lane WS-11)

NIST SP 800-53 Rev.5 AU-10 (Non-repudiation) compliance surface over the
WS-4 hash-chained session ledger.

## Files

- `ledger-types.ts` — structural mirrors of WS-4's `LedgerEntry` /
  `LedgerSnapshot` / `TypedRefusal`, all fields `readonly` (read-only
  surface). Import seam: swap the local declarations for
  `import type { ... } from '../copilot/session-ledger'` at integration;
  one line, no other edits.
- `au10.ts` — pure classification functions. `classifyEntry` maps each
  ledger entry to an evidence class + who/what/when/where coverage;
  `assessAu10Status` returns the mission-plan status
  (`unsigned` / `signed-hardware-verified` / `refused`) as a downgrade
  cascade: empty ledger or broken chain -> `refused`; verified hardware
  attestation binding the CURRENT `tailHash` -> `signed-hardware-verified`;
  otherwise `unsigned`. Missing evidence downgrades, never upgrades.
  The `who` dimension is honestly `missing` (the ledger contract carries
  no actor field); `unsigned` is not green.
- `../components/compliance/ReceiptLedger.tsx` — read-only ledger table
  (no handlers/state/callbacks; structurally lacks any mutation
  affordance), WAI-ARIA table semantics (`scope`d headers, caption,
  `aria-describedby`).
- `../components/compliance/NonRepudiationBadge.tsx` — AU-10 status badge;
  refused renders red, unsigned amber, green only for
  `signed-hardware-verified`.

## Verify

    npx tsc -p tsconfig.check.json --noEmit

with `components/compliance/**/*.tsx` and `lib/compliance/**/*.ts` in
`include`.
