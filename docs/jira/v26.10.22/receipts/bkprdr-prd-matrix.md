# BK-PRDR — PRD §4 court-matrix refresh (receipt-cited, post-board-v1)

**Standing:** **ALIVE** — every cell in the refreshed PRD §4/§4a cites receipt
paths re-read and `[ -f ]`-verified on disk 2026-10-22; standings quoted from
each receipt's own line, never recalled; prose-only verdicts: zero.

Context: solo

Date: 2026-10-22 · Lane: BK-PRDR · Repo: /Users/sac/smalt
Files owned: `docs/jira/v26.10.22/PRD.md` §4 (+ new §4a) + this receipt.
VALIDATION.md v1 (`receipts/bk-boardv3-fold.md`) and the BK-CELLS triage
(`receipts/bkcells-board-triage.md`) were read first; the refreshed §4 rows
mirror those receipts' re-types (BK-SECPEND/BK-VCOURTS: COURT-BOOT-REBIND
ALIVE via `just bkvc-court`; COURT-ATOM-CLAMP PASS; COURT-CERT-OBS ALIVE;
COURT-SYNC-FASTFWD/ANDON typed UNBUILT with falsifier+owner).

## What changed in PRD §4

- In-flight annotations replaced with landed standings: COURT-STORE-PART
  (PARTIAL_ALIVE, BK-69r), COURT-BOOT-REBIND (was "BK-33 in flight" → ALIVE,
  consolidated court `just bkvc-court` leg 1, ×2 exit 0),
  COURT-ATOM-CLAMP/COURT-CERT-OBS (was "needs standalone court file" → named
  consolidated court landed, `justfile.d/51-bkvc.just` +
  `scripts/private_trip.py` verified on disk).
- Zero prose-only verdicts: every cell = standing + receipt path(s), all
  `[ -f ]`-verified (verification table below).
- New §4a added for post-matrix capabilities that landed without a row:
  webpubsub subprotocol echo (KD-166), MHSM fail-closed + DTDL cycle guard
  (EXPL5-T1/T2), kafka recordsCount cross-check, SAS `sb:` host-scoping
  (KD-172/KD-173R), ingest HMAC gate + KD-173 posture, debug faces
  (SMALT_DEBUG_FACES). All six were absent from the old §4; all six now
  carry receipt+standing rows. KD-173 (ingest dev-default HMAC key) is
  typed OPEN posture in its row, not smoothed.
- Count claim: the old §4 named 8 gates in prose with no numeric count
  claim; the refreshed §4 carries 12 rows + §4a carries 6 rows (18 cells,
  2 typed UNBUILT / UNSUPPORTED honestly). No stale count left behind.

## Verification (embedded output)

Every receipt path cited in refreshed PRD §4, `[ -e ]` from
`docs/jira/v26.10.22/`:

```
$ grep -o '`[^`]*receipts/[^`]*`' PRD.md | tr -d '`' | sort -u \
  | while read f; do [ -e "$f" ] && echo "OK $f" || echo "MISSING $f"; done
OK ../v26.10.21/receipts/ja-r3-ja16-defect-fixes.md
OK ../v26.10.21/receipts/pb4-merkle-dual-path.md
OK ../v26.10.21/receipts/ttv4-journal-boot-replay.md
OK receipts/ath1-batch-frame-receiver.md
OK receipts/ath2-nextjs-client.md
OK receipts/az4b-mhsm-receipt.md
OK receipts/az5-webpubsub.md
OK receipts/az5b-webpubsub-receipt.md
OK receipts/bk50-private-trip.md
OK receipts/bk54-private-trip-remediation.md
OK receipts/bk63-sync-interop.md
OK receipts/bk69r-store-reconciliation.md
OK receipts/bk75-kd-final-census.md
OK receipts/bk76-sync-auth-witness.md
OK receipts/bk83-sync-e2e-auth.md
OK receipts/bkbffsec-census.md
OK receipts/bknenv-debug-faces.md
MISSING receipts/bkprdr-prd-matrix.md   <- this lane's own receipt, resolved by this file
OK receipts/bksec-nfr-closures.md
OK receipts/bkvc-consolidated-courts.md
OK receipts/erl4r-vc-twins-lakehouse.md
OK receipts/expl5r1-t1t2-repairs.md
OK receipts/expl7r1-bff-repairs.md
OK receipts/kafka-exp4-repairs.md
OK receipts/kd166-fix-witness.md
OK receipts/kd166-witness.md
OK receipts/kd173r-audience-repair.md
OK receipts/kdsasv-audience-row.md
OK receipts/store4-partition-court.md
```

Exactly one MISSING line, and it is this lane's own receipt before this file
was written (same resolution pattern as the BK-BOARDV3 fold receipt). All
other paths verified OK. Court script files verified: `scripts/private_trip.py`
and `justfile.d/51-bkvc.just` both exist (ls exit 0).

## Standing re-reads (receipt's own line, disk 2026-10-22)

- `kd166-witness.md`: "Standing: **NOT-ALIVE (falsifier run, close condition
  NOT met)**" → superseded by `kd166-fix-witness.md` "Standing: ALIVE (fix
  landed + real-wire witness, close condition met)"
- `az4b-mhsm-receipt.md`: "ALIVE (policy face) / **UNSUPPORTED** (FIPS-level
  hardware isolation — no HSM silicon at loopback; falsifier: a real MHSM
  pool cannot be provisioned on this machine)" — quoted in the §4a cell, not
  smoothed to a bare ALIVE.
- `kdsasv-audience-row.md`: PARTIAL_ALIVE → `kd173r-audience-repair.md`
  ALIVE (host-scoped match, `# KD-COVERS: KD-172`).
- `bkbffsec-census.md`: "Standing: **ALIVE** (census + live probes on a real
  Next dev server; one new registered posture KD-173)".
- `expl5r1-t1t2-repairs.md`: ALIVE (T1 MHSM non-list constraint fail-open →
  fail-closed; T2 DTDL cyclic extends → refusal; court
  `test/internal/expl5r1_court_test.exs`, real court file on disk, ls exit 0)
  in the receipt).
- `kafka-exp4-repairs.md`: ALIVE (F3 recordsCount cross-check,
  `{:error, :record_count_mismatch}`).
- `bknenv-debug-faces.md`: "Standing: **ALIVE**".

## Falsifier

Any receipt path cited in refreshed PRD §4 failing `[ -e ]` post-landing, or
a standing line on disk disagreeing with the §4/§4a cell, reopens this
receipt and the matrix rows.
