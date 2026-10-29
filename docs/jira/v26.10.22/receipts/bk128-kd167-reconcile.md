# BK-128 — KD-167 duplicate-id registrar reconciliation

**Standing:** ALIVE (register + pointer + maa.ex marker reconciled; verification gates green below).
Context: solo

## Before (observed)

`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` carried TWO rows under id KD-167
(concurrent mints, BK-123 disclosed):

- line 347 — KD-167 MHSM key release-policy face (AZ-4, CLOSED-WITH-EVIDENCE,
  receipt `az4-mhsm-policies.md`, shim `lib/smalt/data_plane/skr.ex`)
- line 348 — KD-167 MAA protocol face (AZ-2, OPEN, receipt
  `az2-maa-attestation.md`, shim `lib/smalt/attestation/maa.ex:289`)

## Change

1. Canonical register (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:348`): the
   SECOND KD-167 row (MAA protocol face) renumbered to **KD-168** — id cell
   and its `# KD-COVERS:` cell text.
2. `lib/smalt/attestation/maa.ex:289`: `# KD-COVERS: KD-167` → `# KD-COVERS:
   KD-168` (single marker line; AZ-2 shim court scripts and the AZ-2 receipt
   are point-in-time records and intentionally NOT rewritten).
3. Pointer doc (`docs/jira/v26.10.21/KNOWN_DIVERGENCES.md`): range bumped to
   `KD-01..KD-168 — 165 rows`, next-mint `KD-169`, highest-minted line now
   names KD-166 (AZ-5) / KD-167 (AZ-4) / KD-168 (AZ-2); added missing window
   mint bullets for KD-167 (MHSM release-policy, CLOSED-WITH-EVIDENCE) and
   KD-168 (MAA cross-binding, OPEN).

## After (commands + output)

```
$ python3 scripts/kd_flip.py   # read-only
KD-COVERS covers-map: 114 KD ids from 138 files
  KD-167: [CLOSED-WITH-EVIDENCE] lib/smalt/data_plane/skr.ex
  KD-168: [OPEN] lib/smalt/attestation/maa.ex
(no duplicate-id rows reported; exit 0)

$ just kd-stale
[after this receipt landed]
FLIP-PENDING-WITNESS: 0
exit=0
```

FLIP-PENDING-WITNESS history: immediately after the maa.ex marker edit,
kd_flip showed `FLIP-PENDING-WITNESS: 2 (KD-166, KD-168)` because maa.ex
mtime (1792652932, the marker edit) postdated the az2 receipt
(1792652756). After THIS receipt landed (mtime postdates both shims), the
re-read shows `FLIP-PENDING-WITNESS: 0` — `just kd-stale` clean.

## Falsifier

`grep -c "| KD-167 " docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` returning 2,
or `python3 scripts/kd_flip.py` reporting duplicate ids, reopens this
reconcile.

## Scope note

The pointer doc's KD-166 bullet (Confidential Ledger face) diverges from the
canonical register's KD-166 (Web PubSub handshake), and
`lib/smalt/confidential_ledger/{service,router}.ex` carry `# KD-COVERS:
KD-166` while no Confidential Ledger row exists in the canonical register —
a second concurrent-mint collision, OUTSIDE this lane's ownership
(register+pointer+maa.ex only). Disclosed for the registrar; not fixed here.
