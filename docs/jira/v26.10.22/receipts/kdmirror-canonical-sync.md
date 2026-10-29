# KD-MIRROR — window rows KD-169/171/173 mirrored into canonical register

**Standing:** ALIVE (rows mirrored, gates green)
Context: solo
Date: 2026-10-22
Lane: KD-MIRROR

## Change

Census of window doc `docs/jira/v26.10.22/KNOWN_DIVERGENCES.md` rows KD-169..173
against the canonical register `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` found
three rows missing as register rows (present only as cross-references inside the
KD-170/KD-172 rows):

- KD-169 (Web PubSub server API faces, loopback-open, OPEN)
- KD-171 (BFF sync + bench/debug faces, loopback-open, OPEN)
- KD-173 (N-4 ingest dev default HMAC key, OPEN)

KD-170 and KD-172 were already mirrored (canonical lines 349/350). KD-172's
canonical row already carries the CLOSED-WITH-EVIDENCE flip with the kd173r
repair receipt — nothing owed.

Mirrored the three missing rows verbatim from the window doc into the canonical
table (content identical: surface/divergence/evidence/close-condition/status;
receipt paths absolutized to `docs/jira/v26.10.22/...`). Canonical row count
169 -> 170.

## Embedded census (grep, as run)

```
for id in KD-169 KD-170 KD-171 KD-172 KD-173; do grep -c "$id" canonical; done
KD-169: 2   (cross-refs only, no row)
KD-170: 1   (row present, line 350)
KD-171: 1   (cross-ref only, no row)
KD-172: 1   (row present, line 349)
KD-173: 0
```

After mirror: `grep -o '^| KD-[0-9]*' canonical | sort | uniq -d` -> empty
(zero duplicate ids canonical-wide; 170 rows).

## Flip disposition (KD-172 / KD-173R)

Canonical KD-172 row already flipped CLOSED-WITH-EVIDENCE with receipt
`receipts/kd173r-audience-repair.md`. Receipt-gate verified by mtime:
sas_verifier.ex m=1792669329 < kd173r receipt m=1792669747 (receipt postdates
the shim — gate passes). `python3 scripts/kd_flip.py` read-only re-run after
the mirror: FLIP-ELIGIBLE: 0, FLIP-PENDING-WITNESS: 0, exit 0. No flip
performed or needed; noted per task.

## Gates

```
$ just docs-dod-check   -> exit 0, all rows OK (tail: OK README.md)
$ python3 scripts/kd_flip.py -> FLIP-ELIGIBLE: 0, FLIP-PENDING-WITNESS: 0, exit 0
```

## Note (pre-existing, not introduced)

The window doc's KD-169 row cites evidence receipt
`receipts/expl4r-wirefront-repairs.md`, which does NOT exist on disk
(only `expl4-wirefronts-errc.md`, the finding-origin receipt, exists).
Mirrored verbatim per task; flagged here loudly. docs-dod-check still exits 0,
so the register is not (yet) scanned by that gate for this path.

## Files

- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (3 rows appended at EOF)
- this receipt
