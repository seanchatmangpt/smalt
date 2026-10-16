# WS-11 Receipt — NIST AU-10 Compliance Surface

- Date: 2026-10-15
- Lane: WS-11 (workspace), disjoint paths per `_LANES.md`
- Subject: smalt workspace, branch `main`, files landed uncommitted on the working tree

## Identity (files created)

- `/Users/sac/smalt/workspace/lib/compliance/ledger-types.ts` — structural
  mirrors of WS-4's `LedgerEntry`/`LedgerSnapshot`/`TypedRefusal` (all
  `readonly`), with the documented import seam (one-line swap to
  `import type ... from '../copilot/session-ledger'` at integration).
- `/Users/sac/smalt/workspace/lib/compliance/au10.ts` — pure AU-10
  classification: `classifyEntry` (evidence class + who/what/when/where
  coverage), `assessAu10Status` (downgrade cascade: empty/broken chain ->
  `refused`; verified attestation binding CURRENT tailHash ->
  `signed-hardware-verified`; else `unsigned`), `isGreen`.
- `/Users/sac/smalt/workspace/components/compliance/ReceiptLedger.tsx` —
  read-only ledger table: no state/handlers/callbacks; WAI-ARIA table
  semantics (scoped `th`, caption, `aria-describedby`, row headers).
- `/Users/sac/smalt/workspace/components/compliance/NonRepudiationBadge.tsx` —
  AU-10 status badge; green only for `signed-hardware-verified`; refused
  renders red with an honest description.
- `/Users/sac/smalt/workspace/lib/compliance/README.md` — lane docs.

## Modification outside lane paths (disclosed)

- `/Users/sac/smalt/workspace/tsconfig.check.json` (WS-1 scaffold): added
  `components/compliance/**/*.tsx` + `lib/compliance/**/*.ts` to `include` —
  required so the lane is actually type-checked by the shared check config.

## Verification (real gate, actual output)

- `cd /Users/sac/smalt/workspace && npx tsc -p tsconfig.check.json --noEmit`
  -> exit 0, no diagnostics, AFTER adding the compliance lanes to `include`
  (a first run also exited 0 but did not cover the new files; the
  meaningful receipt is the post-include run).
- Files re-read from disk (`ls -la`): 5 files present as listed above.

## Standing

- PARTIAL_ALIVE: tsc-verified, zero runtime/court runs (no test harness for
  this lane in scope). Honest limits recorded in `au10.ts`: the `who`
  dimension is always `missing` under the WS-4 contract (no actor field);
  `unsigned` never renders green; `signed-hardware-verified` is reachable
  only via an explicit `Au10Attestation` bound to the current `tailHash`.

## Falsifiers

- Mutate a copied ledger snapshot (`intact: false`) -> badge must render
  `refused`, never green.
- Any mutation affordance added to `ReceiptLedger` violates the lane
  contract — the file must contain no `onClick`/`onChange`/state.
