# BK-PRD5 — PRD §5 tightening + FINAL-RELEASE freshness refresh

**Standing: ALIVE** — every tightened row cites a receipt whose standing line was
re-read from disk this session (not recalled); census re-run mechanically.
Context: solo
Date: 2026-10-22 · Lane BK-PRD5 · Scope: `docs/jira/v26.10.22/PRD.md` §5,
`docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md`, this receipt.

## Trigger

BK-PRDR flagged PRD §5 still describing the COURT-ATOM-CLAMP/CERT-OBS
named-court consolidation as a "small WO" after it landed
(`receipts/bkvc-consolidated-courts.md` ALIVE); FINAL-RELEASE had absorbed
landings since its last refresh (bk10c census, kdsync pointer sync).

## Edits

### PRD §5 (docs/jira/v26.10.22/PRD.md)

- Gate 0: consolidation ✔ LANDED (`just bkvc-court` ×2, `Result: 7 passed`;
  bkvc receipt ALIVE, adjacency 33/33). Remaining Gate-0 WO re-scoped to
  COURT-MERKLE-O1 standalone court (still PARTIAL_ALIVE per §4).
- Gate 1: BK-33 rebind "in flight" was stale — RESOLVED via
  `../v26.10.21/receipts/bk33-warm-restart-rebind.md` (existence verified);
  store4 partition court ALIVE 4/4 ×3 cited; remaining residue = named
  `ttv5_store_partitioning_court.exs` receipt pairing.
- Gate 2: SYNC-1 batch receiver LANDED ALIVE (ath1 11/11 + sync1-batch-receiver
  finish-and-relay ALIVE); FR-SNC-005/006 stay queued.
- Gate 3: private-trip LANDED GREEN (bk50 RED → bk54 remediation ALIVE,
  `just court` wiring); witness-all still open (bk95 attempt-1 PARTIAL_ALIVE,
  typed reds); HEAD sweep full green still open (bkseal PARTIAL_ALIVE with
  three typed lane residues).
- New-WO ledger re-typed: (a) consolidation LANDED except COURT-MERKLE-O1;
  (d) COURT-PRIVATE-TRIP LANDED; (b)/(c) FR-SNC-005/006 remain OPEN.
- §6/§7: not present in this PRD (sections end at 4a/5).

### FINAL-RELEASE-26.10.22.md

- Gate ledger: SYNC-1 row flipped IN-FLIGHT → CLOSED ALIVE (real landed receipt
  is `sync1-batch-receiver.md`, not the speculative `sync1-fastfwd.md` path);
  BK-50 row PENDING-GATE → CLOSED ALIVE on bk54; BK-44 row now cites bk95
  attempt-1 PARTIAL_ALIVE; BK-35 row cross-references BK-SEAL evidence;
  new row BK-VCOURTS (CLOSED ALIVE, VALIDATION PENDING-zero).
- New Gate-3 row: BK-SEAL full-green HEAD sweep (PARTIAL_ALIVE — stages
  1/3/4/5/6 exit 0; stage-2 census fences type 3 in-flight lanes: BK-AMQPF
  allowlist, BK-EPLAW sleep removal, KD-173R status-literal asserts).
- KD census re-run mechanically (same `awk -F'|'` convention, `$(NF-1)` status
  cell): **171 rows** (was 167 at kdsync), CLOSED **160** (86 CLOSED-SIMULATED,
  35 CLOSED-WITH-RECEIPT, 21 CLOSED-WITH-EVIDENCE, 11 CLOSED-OBSOLETE,
  5 `CLOSED-with-receipt`, 2 CLOSED), OPEN **5** (KD-168, KD-169, KD-171,
  KD-173, KD-174), PINION 2 + PINION-WITNESSED 2, ENVIRONMENT-PINION 1,
  UNSUPPORTED-BY-COST 1; 160+5+4+1+1=171, no skew. KD-172 has closed
  (CLOSED-WITH-EVIDENCE via `receipts/kd173r-audience-repair.md`); window rows
  KD-169/171/173 now mirrored into the canonical table; KD-174 minted since.
- Path-verification section notes the BK-PRD5 re-verification set.

## Embedded verification output

```
$ awk -F'|' '/^\| KD-/ {s=$(NF-1); gsub(/^ +/,"",s); split(s,a," "); print a[1]}' \
    docs/jira/v26.10.14/KNOWN_DIVERGENCES.md | sort | uniq -c | sort -rn
  86 CLOSED-SIMULATED
  35 CLOSED-WITH-RECEIPT
  21 CLOSED-WITH-EVIDENCE
  11 CLOSED-OBSOLETE
   5 OPEN
   5 CLOSED-with-receipt
   2 PINION-WITNESSED
   2 PINION
   2 CLOSED
   1 UNSUPPORTED-BY-COST
   1 ENVIRONMENT-PINION

$ awk -F'|' '/^\| KD-/ {s=$(NF-1); gsub(/^ +/,"",s); if (s ~ /^OPEN/) print $2}' \
    docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
 KD-168
 KD-169
 KD-171
 KD-173
 KD-174

$ awk '/^\| KD-/' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md | wc -l
171

$ grep -c PENDING docs/jira/v26.10.22/VALIDATION.md
8          # all 8 hits are prose/lineage; row-level PENDING cells = 0 per §4:
           # "Row-level PENDING cells in this board: 0" (VALIDATION.md line 84);
           # the §3 Gate-3 row's PENDING-GATE is typed as PARTIAL_ALIVE residue,
           # not a PENDING cell.

$ for f in bk54-private-trip-remediation bk95-witness-full bk67-witness-census \
           bkseal-full-green bkvc-consolidated-courts sync1-batch-receiver \
           kd173r-audience-repair; do [ -f receipts/$f.md ] && echo "OK $f"; done
OK bk54-private-trip-remediation
OK bk95-witness-full
OK bk67-witness-census
OK bkseal-full-green
OK bkvc-consolidated-courts
OK sync1-batch-receiver
OK kd173r-audience-repair
```

## Cross-check (task item 3): VALIDATION.md PENDING

`grep -n PENDING docs/jira/v26.10.22/VALIDATION.md` → 8 matches, of which:
1 methodology prose (line 18), 1 typing-convention prose (line 47), the §3
Gate-3 seal row typed PARTIAL_ALIVE "PENDING-GATE on 5 rows" (line 64), the §4
PENDING-ledger heading + its own zero-count statement (lines 82–91). **Row-level
PENDING cells: 0** — matches the board's own §4 claim; confirmed true on disk.

## Standing basis

ALIVE: every claim in the two docs re-verified against disk receipts this
session; census is a fresh mechanical run embedded above. Residual UNKNOWN:
whether the three BK-SEAL-typed lanes have registered their census files since
`bkseal-full-green.md` was written — not re-run here (that gate belongs to the
BK-SEAL lane's flip, not this docs lane).
