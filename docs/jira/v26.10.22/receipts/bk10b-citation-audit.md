# BK-10b — Citation Audit of FINAL-RELEASE-26.10.22.md

**Standing:** **PASS** (1 stale-count finding, 0 broken citations, 0 unindexed receipts)

Context: solo

Date: 2026-10-22. Read-only audit of `docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md` (66 lines).
Audited document untouched (flag-don't-fix). All commands rerun on the live tree.

## (1) Receipt-path existence (docs-dod class)

All 23 distinct paths cited in the gate ledger + census section exist on disk
(relative to repo root):

```
OK  docs/jira/v26.10.21/receipts/ja-r3-ja16-defect-fixes.md
OK  docs/jira/v26.10.21/receipts/ttv4-journal-boot-replay.md
OK  test/integration/ttv5_store_partitioning_court.exs
MISS docs/jira/v26.10.22/receipts/ttv5-store-partitioning.md   (EXPECTED — row says IN-FLIGHT)
OK  docs/jira/v26.10.21/receipts/bk33-warm-restart-rebind.md
OK  docs/jira/v26.10.22/receipts/ath2-nextjs-client.md
OK  docs/jira/v26.10.22/SYNC-CHARTER.md
MISS docs/jira/v26.10.22/receipts/sync1-fastfwd.md             (EXPECTED — IN-FLIGHT)
MISS docs/jira/v26.10.22/receipts/fr-snc-005.md / fr-snc-006.md (EXPECTED — QUEUED)
OK  docs/jira/v26.10.22/receipts/bk50-private-trip.md
MISS docs/jira/v26.10.22/receipts/bk44-witness-all.md          (EXPECTED — PENDING-GATE)
MISS docs/jira/v26.10.22/receipts/bk35-head-court-sweep.md     (EXPECTED — PENDING-GATE)
OK  docs/jira/v26.10.21/receipts/ttv7b-quiesced-rerun.md
OK  docs/jira/v26.10.22/receipts/bk53-finalrelease-draft.md
MISS docs/jira/v26.10.22/receipts/bk53-finalrelease-seal.md    (EXPECTED — PENDING-GATE)
OK  docs/jira/v26.10.22/receipts/bk75-kd-final-census.md
OK  docs/jira/v26.10.22/PRD.md
OK  docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
OK  docs/jira/v26.10.21/receipts/bk48-pinion-witness.md
OK  justfile.d/48-private-trip.just
OK  scripts/private_trip.py
OK  tmp/bench/ttv7_gl9_warmed.exs
```

The 8 MISSING paths are exactly the rows the doc itself types as IN-FLIGHT /
QUEUED / PENDING-GATE (expected receipts, not live citations). Zero unexpected
missing citations. The doc's own "14/14 OK" claim (line 59) covers the draft-time
closed citations; my re-run confirms 15/15 live citations exist today (14 +
`KNOWN_DIVERGENCES.md`, which the draft count excluded).

## (2) Number anchoring

| claim (file:line) | anchor | verdict |
|---|---|---|
| L15 Gate 0 JA-R3 PASS | `docs/jira/v26.10.21/receipts/ja-r3-ja16-defect-fixes.md` — "Standing: PASS" | OK |
| L16 TTV-4 ALIVE | `ttv4-journal-boot-replay.md` — "Standing: **ALIVE**" | OK |
| L18 BK-33 RESOLVED | `bk33-warm-restart-rebind.md` — "RESOLVED / ALIVE" | OK |
| L19 ATH-2 "ALIVE (browser) / PARTIAL (sync leg)" | `ath2-nextjs-client.md` — "ALIVE (browser surface); sync server leg PARTIAL_ALIVE" | OK |
| L22 BK-50 "41 hits" | `bk50-private-trip.md:55` embedded output: `PRIVATE-TRIP REFUSE: 41 hit(s) in 27 file(s)` | OK |
| L22 "gate wired into `just court`" | root `justfile:278-279` imports `justfile.d/48-private-trip.just`; recipe `private-trip` calls `scripts/private_trip.py` | OK |
| L25 TTV-7b BLOCKED-ON-QUIESCENCE, re-run `tmp/bench/ttv7_gl9_warmed.exs` at load < ~2× cores | `ttv7b-quiesced-rerun.md:6` states both verbatim | OK |
| L26 docs-dod exit in bk53 draft receipt | `bk53-finalrelease-draft.md:40` "docs-dod-check EXIT=0" | OK |
| L28-54 KD census **160 total / 152 CLOSED** | anchors to `bk75-kd-final-census.md` (2026-10-21) — but the register on disk today is **166 rows, 158 CLOSED-family** (KD-164..KD-168 landed since) | **STALE** — finding F1 |

Fresh measurement (this audit):

```
$ awk -F'|' '/^\| KD-[0-9]+/{s=""; for(i=2;i<=NF;i++) if($i ~ /[A-Za-z]/) s=$i; print s}' \
    docs/jira/v26.10.14/KNOWN_DIVERGENCES.md | sed -E 's/^ *([A-Z-]+).*/\1/' | sort | uniq -c | sort -rn
  95 CLOSED-SIMULATED
  32 CLOSED-WITH-RECEIPT
  13 CLOSED-WITH-EVIDENCE
  11 CLOSED-OBSOLETE
   5 CLOSED-* (other faces)
   2 CLOSED (bare)
   2 PINION-WITNESSED
   2 PINION
   2 OPEN (KD-88, KD-153 — unchanged)
   1 ENVIRONMENT-PINION (KD-162)
   1 UNSUPPORTED-BY-COST (KD-90)
```

158 CLOSED + 2 OPEN + 4 PINION + 1 ENVIRONMENT-PINION + 1 UNSUPPORTED-BY-COST = 166.
Distribution shape identical to the doc's claims; only the totals moved
(160→166, 152→158). OPEN/pinion/environment/unsupported row identities match the
doc exactly.

## (3) UNANCHORED claims

None. Every claim carries either a receipt anchor (verified above) or an
as-of-date marker. The census block is dated "fresh, 2026-10-21" and names its
superseding receipt (`bk75-kd-final-census.md`), so F1 is staleness, not
absence of anchor.

## (4) Receipt-index membership

`python3 scripts/receipt_index.py` exit 0. All 9 named live receipts appear in
their milestone RECEIPTS.md tables (v26.10.21: ja-r3, ttv4, bk33, ttv7b,
bk48-pinion-witness; v26.10.22: ath2, bk50, bk53-draft, bk75).

```
ja-r3-ja16-defect-fixes: v21=1   ttv4-journal-boot-replay: v21=1
bk33-warm-restart-rebind: v21=1  ath2-nextjs-client: v22=1
bk50-private-trip: v22=1         ttv7b-quiesced-rerun: v21=1
bk53-finalrelease-draft: v22=1   bk75-kd-final-census: v22=1
bk48-pinion-witness: v21=1
```

Note: `receipt_index.py` regenerates INDEX.md/RECEIPTS.md files as a side
effect; the working tree now carries regenerated indexes reflecting other
lanes' receipts. Left uncommitted for the coordinator (one writer per file);
my commit contains only this receipt.

## Findings (ranked)

**F1 (only finding, MED)** — `FINAL-RELEASE-26.10.22.md:31,35,51` — KD census
totals stale: doc says 160 rows / 152 CLOSED anchored to bk75 (2026-10-21);
current register is 166 rows / 158 CLOSED (KD-164..KD-168 landed since).
Per the receipt-cited-counts law the seal flip should re-run the census and
refresh the three numbers (row identities all unchanged: OPEN KD-88/KD-153,
pinions KD-05/101/159/160, KD-162, KD-90). bk75's own receipt already types
this class: "One cross-doc staleness named below (pointer doc distribution
lines, not the register itself)."

No broken citations, no unindexed receipts, no unanchored claims. Seal
condition path (L64-66) is mechanically sound.
