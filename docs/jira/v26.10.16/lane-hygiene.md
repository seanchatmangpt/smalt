# Lane-Hygiene Audit — v26.10.16 (2026-10-16)

Skill lane: smalt-lane. Read-only audit; coordinator lands doc + owns deletions.

## 1. Build-root inventory (NOT deleted by this lane)

44 `_build-lane*` roots on disk, **25.1 GB**. W14-drained lanes still holding
roots (10): 520, 521, 523, 524, 525, 526, 432, 529, 430, plus 433 (in-flight,
expected). **23 orphaned roots** with no W14 row (15, 23, 83, 161, 167, 233,
239, 276, 310, 354, 365, 391, 419, 422–429, 500–511) hold ~11.7 GB — residue
of earlier waves, never in any lane-clean scope.

**H1**: integration incomplete — `just lane-clean` (dry first) reclaims ~25 GB;
orphan roots sweep; env-live guard SKIPs live roots.

## 2. SLA disclosure chain (rule 6: BOTH lanes' receipts)

| # | Fix | Verdict |
|---|---|---|
| 1 | sb_rules char-literal (lane 430) | INCOMPLETE — no receipt-side record |
| 2 | router stale-cond (lane 521) | PARTIAL — own receipt only |
| 3 | cosmos record_key + router rg_name (lane 526) | INCOMPLETE — counterparty receipts lack the disclosure |

**H2**: 1/3 complete on receipts; `_LANES.md` W14 + WRAP_LEDGER W15 carry the
chain of record. Counterparty disclosures to be folded into the wrap's receipt
regen pass (receipts are the standing record; the chain is disclosed in both
ledgers).

## 3. Leases past scope

Drained-but-holding: 10 roots (lane-clean). Undocumented holders: 23 orphans.
In-flight lanes within scope. Lane 434 has no build root (expected — never
built).

## Coordinator actions

- `just lane-clean-dry` → `just lane-clean` at integration (before final
  commit), per the cleanup law.
- Disclosure chain: WRAP_LEDGER W15 note is the standing record; counterparty
  receipt disclosures folded in at receipt-index regen.
