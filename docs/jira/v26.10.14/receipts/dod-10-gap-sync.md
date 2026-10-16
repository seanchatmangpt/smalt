# Receipt — DoD-10 gap/defect register sync

- Lane: DoD-10 (documentation truth-sync) · Repo `/Users/sac/smalt` (canonical checkout, main, v26.10.14 working tree) · 2026-10-15
- Scope: docs only — no `lib/`, no `test/`, no git state changes, no commits.

## Work orders executed

1. **`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (new)** — register of the SDK-wave
   divergences, built from all 10 receipts in `sdk-results/` plus
   `receipts/18-mutation-courts.md`: **35 registers (KD-01..KD-35), all OPEN** —
   table columns: id / surface / divergence / evidence receipt / close condition
   (fix-shape or typed-UNSUPPORTED) / status. Includes the cross-check section
   (no contradiction with existing GAP tokens; KD-19 folds under
   `GAP(eventhubs-partition-metadata-absent)`; KD-04 registers only the
   `InvalidQueryParameter` vs `InvalidQueryParameterValue` name delta) and the
   doc-truth flag on the WIRE_PARITY Event Hubs wire-lane row's stale
   smoke-tier citation.
2. **`docs/WIRE_PARITY.md`** — appended "SDK-wave divergence register
   cross-reference (2026-10-15)" section: points the register, states no GAP
   token is contradicted (KD-19 fold + KD-04 name-delta notes), and flags the
   `:149` Event Hubs wire-lane row's smoke-tier citation as stale (wire-tier
   claim stands). No existing row edited.
3. **`justfile.d/10-gap-register-sync.just`** — `gap-sync` recipe (bash shebang
   recipe, `set -euo pipefail`): asserts 35 well-formed KD rows, all unique ids
   KD-01..KD-35, every row's status cell OPEN; WIRE_PARITY census = 2
   strikethrough CLOSED tokens + 3 CLOSED rows at `C1_ARM_REST.md:83-85`
   (= lane-13's 5 CLOSED-with-receipt), 9 typed-UNSUPPORTED live GAP tokens,
   lane-13 census lines present in `receipts/13-gap-register.md`, and the
   WIRE_PARITY cross-reference section citing KNOWN_DIVERGENCES.md + KD-04.
   Exit 1 on drift with a typed DRIFT message.

## Run receipt (actual output)

```
$ just -f justfile.d/10-gap-register-sync.just gap-sync
gap-sync: OK — 35 KD registers all OPEN; WIRE_PARITY census matches lane-13 (5 CLOSED-with-receipt, 9 typed-UNSUPPORTED); no contradictions.
rc=0
```

Drift falsifier witnessed: appending a fake `| KD-99 | ... | CLOSED |` row →
`rc=1` with DRIFT message (status-cell check); row removed, re-run `rc=0`.

## Census reconciliation (measured on disk)

- lane-13 receipt census: 5 CLOSED-with-receipt — verified as 2 strikethrough
  tokens in WIRE_PARITY:124 (`blob-error-envelope-json`,
  `blob-x-ms-error-code-header-absent`) + 3 CLOSED register rows at
  `C1_ARM_REST.md:83-85` (`lro-no-failed-path`, `lro-lazy-terminality`,
  `lro-retention-unbounded`). Matches.
- 9 typed-UNSUPPORTED live GAP tokens in WIRE_PARITY — matches lane-13's nine.
- 35 net-new SDK-wave divergences registered OPEN; zero duplicates of existing
  tokens; one overlap (KD-19) referenced, not duplicated.

## Standing

ALIVE — `gap-sync` green on the exact subject (rc=0 output above); drift
falsifier executed once and passed (rc=1 on injected drift).
