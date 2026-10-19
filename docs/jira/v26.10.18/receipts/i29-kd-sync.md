# i29 — KD register sync (read-only audit)

Standing: PASS (audit-only; no flips applied, no register edits, no git)

## Commands (real output)

    $ python3 scripts/kd_flip.py        # read-only default; --dry-run is not a valid flag
    KD-COVERS covers-map: 16 KD ids from 20 files
      KD-03: [CLOSED-WITH-RECEIPT] lib/smalt/data_plane/blob_service.ex
      KD-15: [CLOSED-WITH-RECEIPT] lib/smalt/auth/bearer.ex, lib/smalt/egress_router.ex
      KD-22: [CLOSED-SIMULATED] lib/smalt/data_plane/sentinel.ex
      KD-52: [CLOSED] lib/smalt/data_plane/blob_storage.ex, lib/smalt/data_plane/cosmos.ex
      KD-53: [CLOSED-SIMULATED] lib/smalt/egress_router.ex, lib/smalt/messaging/event_hubs.ex
      KD-54: [CLOSED-SIMULATED] lib/smalt/application.ex
      KD-60: [CLOSED-SIMULATED] lib/smalt/c... (truncated in receipt; full output preserved in session)
    FLIP-ELIGIBLE: 0
    FLIP-PENDING-WITNESS: 0
    EXIT=0

    $ grep -rn "KD-COVERS" lib workspace/lib   # 60 token sites, 27 distinct ids (03,15,18,19,20,21,22,45,46,49,52,53,54,60,68,70,71,76,77,80,81,82,87,89,91,94,97)
    $ grep -c "^| KD-" docs/jira/v26.10.14/KNOWN_DIVERGENCES.md   # 95 table rows

## Findings

1. FLIP-ELIGIBLE = 0. Every KD id carrying a `# KD-COVERS` token in lib/ or
   workspace/lib already has a closed-class row; no OPEN row has a shim token,
   so no row can flip on this pass. Coordinator flip pass would be a no-op.
2. No OPEN row has a witness receipt in docs/jira/v26.10.18/receipts/ newer
   than a covering shim (mechanically confirmed by the tool: 0 pending).
3. Register is the newest KNOWN_DIVERGENCES.md on disk:
   docs/jira/v26.10.14/KNOWN_DIVERGENCES.md (canonical; v26.10.16 copy is a
   pointer). Table = 95 rows, KD-01..KD-97, 55 OPEN-class / 40 closed-class.
   The prose census in the doc body still reads "88 rows / 60 OPEN-class" —
   stale vs the table; table is ground truth per repo convention.

## Progress-since-filing (OPEN rows, receipts naming the id)

- KD-69: docs/jira/v26.10.18/receipts/w16-review.md (2026-10-18) — KD-68/KD-69
  falsifier courts converted (selector_epoch_test.exs). Progress, not
  flip-eligible: no KD-COVERS token for KD-69, receipt is a test-conversion
  receipt, not a PASS witness naming a close condition.
- KD-04: docs/jira/v26.10.17/receipts/i21b-coordinator-flips.md — fix landed
  2026-10-17 (token rename), flip pending witness. No token, so kd_flip
  cannot flip it even with a witness; needs a KD-COVERS site first.
- KD-13 / KD-75: routes landed 2026-10-17 (egress_router.ex:723-752),
  receipt kd13-kd75-softdelete-routes-witness.md — in-row notes; still no
  KD-COVERS token, so not flip-eligible.
- KD-79: docs/jira/v26.10.17/receipts/i3-witness-sweep.md (product-gap
  ruling) — stays OPEN by design (loopback-by-design constant).
- KD-92: docs/jira/v26.10.17/receipts/i21-surfaces-postfix.md;
  KD-93: docs/jira/v26.10.17/receipts/r243-terminal-receipt.md — referenced,
  both remain OPEN (no shim, no closing witness).

## Zero-progress OPEN rows (no token, no post-filing receipt naming the id)

KD-02, 05, 06, 08, 09, 11, 12, 16, 17, 24, 25, 26, 27, 28, 29, 30, 31, 32,
33, 34, 35, 36, 44, 47, 48, 50, 51, 55, 56, 57, 58, 59, 61, 62, 64, 65, 66,
67, 72, 73, 74, 84, 85, 86, 88 (45 rows).

KD-10, KD-14, KD-23 carry audit notes that BLOCK their close conditions
(fix unverified / wrong-plane receipt / no fix site) — filed progress
disclosures, zero progress since.
