# BK-SUSP3 — residual SUSPECT close: bucket-(a) successor dispositions + cost3/cost4

- **Standing**: ALIVE — all 7 dispatched rows dispositioned with on-disk
  evidence; 30 → 23 suspects (exactly the dispatched set, none else moved).
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-SUSP3

## Embedded counts (real, before/after)

```
$ python3 scripts/receipt_index.py   (before addenda)  -> receipts=1413 sdk=61 total=1474 suspects=30
$ python3 scripts/receipt_index.py   (after addenda)    -> receipts=1416 sdk=61 total=1477 suspects=23
$ diff of SUSPECT sets               -> exactly 06-blob-x-ms-date-unvalidated,
  i29-court-x2-final, kd116-sb-session-delivery-shape-tbd,
  k8-tail-rows-dispositions-kd114-115-116, w6p-table-storage,
  cost3-egress-quantification, cost4-migration-displacement removed; none added
```

## Per-row dispositions (original evidence untouched in every file)

**Bucket (a) — stale/disposition rows:**

1. `06-blob-x-ms-date-unvalidated.md` (v26.10.14) — **NOT superseded; typed
   current-as-of-2026-10-22 with owner**. On-disk probe: GAP token still live
   in `docs/WIRE_PARITY.md` (`grep -c` = 1, exit=0), zero `x-ms-date` sites in
   `lib/smalt/egress_router.ex` (exit=0) and none in the blob courts
   (`test/data_plane/blob_hardening_test.exs`,
   `test/wire/egress_wire_test.exs` — exit=2, no matches). The date-fence that
   DID land is the sibling x-ms-version grammar validation
   (`KD-COVERS: KD-67`, `plausible_version_value?/1`); it does not cover
   x-ms-date. Addendum re-verifies the UNSUPPORTED typing as current and names
   the owner: the cross-plane header-validation seam lane this receipt already
   scopes. No successor exists; none fabricated.
2. `i29-court-x2-final.md` (v26.10.18) — **SUPERSEDED-BY**
   `docs/jira/v26.10.19/receipts/v261019-12-court-x2-close.md` (six parsed
   two-green court-x2 pairs with rc=0 verdict tails and pinned HEADs; verified
   present, 18 rc=0 lines, exit=0). Later seals
   (`bkseal-full-green.md`, `bkseal3-quiesced-rerun.md`) carry the current
   posture.
3. `kd116-sb-session-delivery-shape-tbd.md` (v26.10.19) — **SUPERSEDED-BY**
   `docs/jira/v26.10.20/receipts/kd115-116-diagnosis.md` §4 (PASS
   kd116-session-settle: settled 3/3,
   re-receive 0) + canonical register row
   `docs/jira/v26.10.19/KNOWN_DIVERGENCES.md:33` (CLOSED-WITH-RECEIPT,
   2026-10-21). Verified: 2 PASS-line hits (exit=0), 1 register-row hit
   (exit=0).
4. `k8-tail-rows-dispositions-kd114-115-116.md` (v26.10.20) — all three HEAVY
   dispositions superseded by later register flips: KD-114 CLOSED-SIMULATED
   (`kd114-sharedkey-close-witness.md`), KD-115 CLOSED-SIMULATED
   (`kd115-post-shim-witness.md`), KD-116 CLOSED-WITH-RECEIPT
   (`kd115-116-diagnosis.md` §4) — canonical register
   `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:295-296`. Verified: all 4 witness
   files present (exit=0 ×4), 2 CLOSED-SIMULATED register hits (exit=0).
5. `w6p-table-storage.md` — **SUPERSEDED-BY** the w6bk plane-fence fix
   (`docs/jira/v26.10.20/receipts/w6bk-plane-fence.md`) +
   `w6o-file-share.md`; the audited premise re-verified against current
   source (`lib/smalt/data_plane/table_storage_router.ex:19-32`: every arm
   literal `["tables", ...]`-prefixed with `when t != "tables"` guards,
   exit=0).

**Bucket (b) — cost3/cost4: claims still anchor → exit-captured replay, not
retirement.**

6/7. `cost3-egress-quantification.md`, `cost4-migration-displacement.md`
   (v26.10.20) — every cited artifact on disk with unchanged `_meta.fetched_at`
   pins (rate-card.json 2026-10-21T17:24:58Z, rate-card-egress.json
   17:53:38Z), meterIds match (`65d4ded2-…`, `9d0c5c5c-…`, `6bd64e8e-…`), and
   the arithmetic reproduces exactly: cosmos floor $0.008×730 = $5.84000,
   SB floor $0.013441×730 = $9.81193, 500 GB egress scenario $32.00 — all
   MATCH the receipts' figures. REPLAY PASS, exit=0. Typed
   claims-still-anchor with embedded replay; RETIRED-successor would have been
   fabrication.

## Residual 23 (out of BK-SUSP3 scope)

- 5 bench rows: SUSPECT-PERMANENT-with-owner (bench-runner agent class on a
  quiesced machine) — per coordinator, out of scope.
- 16 coordinator re-witness-wave rows (errc4-hdr, lc1-8hop-tax-chain,
  otp29-capability-probes, powl2-wave-skeptic, scvd-backpressure-audit,
  w30-health-probe-pattern, w32-api-conformance, w6a, w6ab, w6ac, w6an, w6ao,
  w6aq2, w6be, w6l, wasm-memory-cdp-witness) + 2 newly-landed-by-other-lanes
  SUSPECTs (bkaud2-lane-accounting, bkmcpsha-sha-fix).

## Files committed (explicit paths)

- docs/jira/v26.10.14/receipts/06-blob-x-ms-date-unvalidated.md
- docs/jira/v26.10.18/receipts/i29-court-x2-final.md
- docs/jira/v26.10.19/receipts/kd116-sb-session-delivery-shape-tbd.md
- docs/jira/v26.10.20/receipts/k8-tail-rows-dispositions-kd114-115-116.md
- docs/jira/v26.10.20/receipts/w6p-table-storage.md
- docs/jira/v26.10.20/receipts/cost3-egress-quantification.md
- docs/jira/v26.10.20/receipts/cost4-migration-displacement.md
- docs/jira/v26.10.22/receipts/bksusp3-residual-close.md (this receipt)

Not committed (left for coordinator integration — generator's own diff from
the index re-run, shared with concurrent lanes): regenerated RECEIPTS.md +
receipts/INDEX.md across windows.

## Falsifier

1. Each addendum's probe is re-runnable verbatim; a divergent result (e.g.
   x-ms-date validation landing without a successor receipt, or a witness
   file disappearing) reopens the row.
2. `python3 scripts/receipt_index.py` reports suspects=23 with all seven
   dispatched rows absent; a regression with no new receipts refutes the
   clearing.
3. The cost replay reproduces exactly from
   `popcorn_demo/azurite-spike/rate-card.json` +
   `rate-card-egress.json`; any figure drifting from the receipts'
   pinned numbers (5.84 / 9.81193 / 32.00) refutes the
   claims-still-anchor typing and mandates RETIRED-successor.
