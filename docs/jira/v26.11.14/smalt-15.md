# smalt-15-gcp-parity-receipt-and-kd-gcp-close

Standing: UNVERIFIED

## Problem

`/Users/sac/smalt/docs/gcp-parity/` holds GS1..GS6, SF1, SM2/4/5, SW1..4 receipts and
`KD-GCP-CANDIDATES.md`
(Standing: PARTIAL, historical; rows merged as KD-GCP-01..05 at KNOWN_DIVERGENCES.md lines
378-382, all OPEN). This session observed `mix test /Users/sac/smalt/test/gcp
/Users/sac/smalt/test/aws` at 76 passed, but no
GCP receipt records that result against exact HEAD. KD-GCP-04 (logging filter grammar limited to
AND of four fields) is pinned in `/Users/sac/smalt/test/gcp/run_logging_test.exs`. Test files exist
for
firestore, pubsub, storage, identity, secrets/kms, run/logging.

## Acceptance

- Command: `mix test /Users/sac/smalt/test/gcp` from /Users/sac/smalt; expected: 0 failures.
- `/Users/sac/smalt/docs/gcp-parity/GCP_WIRE_PARITY.md` gains a dated run line (command, exit,
  count).
- Each KD-GCP-01..05 row in KNOWN_DIVERGENCES.md names a witness file or stays OPEN with reason.

## Falsifier

A KD-GCP row flips to CLOSED with no receipt path, or GCP_WIRE_PARITY.md records a count that
differs from the live run.

## Owned files

- /Users/sac/smalt/docs/gcp-parity/GCP_WIRE_PARITY.md,
  /Users/sac/smalt/docs/gcp-parity/KD-GCP-CANDIDATES.md,
  /Users/sac/smalt/docs/gcp-parity/REVIEW-GS.md
- /Users/sac/smalt/lib/smalt/gcp (read only)

## Depends-on

None.

## Size

S

## Result

Standing: UNVERIFIED

Edited only (no execution): /Users/sac/smalt/docs/gcp-parity/GCP_WIRE_PARITY.md (+11),
KD-GCP-CANDIDATES.md (+12), REVIEW-GS.md (+5). KNOWN_DIVERGENCES.md not owned; rows stay OPEN,
witness map in KD-GCP-CANDIDATES.md.
Acceptance for coordinator: from /Users/sac/smalt run mix test on /Users/sac/smalt/test/gcp,
then replace PENDING cells in GCP_WIRE_PARITY.md Run log with exit/count/HEAD.

## References (path : LOC)

- /Users/sac/smalt/docs/gcp-parity/ : 24 files, 535 lines total
- /Users/sac/smalt/docs/gcp-parity/GCP_WIRE_PARITY.md : 30 lines
- /Users/sac/smalt/docs/gcp-parity/KD-GCP-CANDIDATES.md : 13 lines
- /Users/sac/smalt/docs/gcp-parity/REVIEW-GS.md : 48 lines
- /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:378-382 (5 lines of 386)
- /Users/sac/smalt/test/gcp/run_logging_test.exs : 87 lines
- /Users/sac/smalt/test/gcp/ : 9 files, 860 lines total
- /Users/sac/smalt/lib/smalt/gcp/ : 17 files, 3579 lines total
- /Users/sac/smalt/test/aws/ : 7 files, 522 lines total

## Repair

Standing: UNVERIFIED

- M4: GCP_WIRE_PARITY.md header no longer says no code ran; states the 76-passed run is not
  HEAD-tied and the Run log is a PENDING placeholder. Run line still needs coordinator's live run.
- L1: KD-GCP-CANDIDATES.md line ranges corrected to 380-384 (rows 01..05).
- Rerun: smalt gcp test dir per ticket acceptance; fill Run log row.
