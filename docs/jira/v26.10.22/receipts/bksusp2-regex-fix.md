# BK-SUSP2 — receipt_index.py evidence-regex fix (EXIT=/RC=/rc=N accepted)

- **Standing**: PARTIAL_ALIVE — fix landed and proven non-vacuous on scratch
  probes; SUSPECT count on the live corpus is unchanged (43 → 43) because the
  dispatch premise ("31 of the residual 43 are regex-invisible EXIT=/RC=
  spellings") is refuted by the run: the residual 43 contain zero exit-status
  tokens in any spelling.
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-SUSP2

## Fix

`scripts/receipt_index.py` `EVIDENCE_PATTERNS` now also accepts (word-bounded,
case-insensitive): `EXIT=N`, `RC=N` (covers `rc=N`), `exit code N`. Bare
numbers are still refused — a receipt with zero exit-status tokens anywhere
stays SUSPECT. `extract_standing/1` shares no exit-code pattern (it matches
standing tokens only) and needed no change.

## Non-vacuity (scratch probes, embedded real output)

```
$ python3 - <<EOF  (assertions over receipt_index.has_evidence)
not has_evidence("...12 monkeys and the word passim.\n")   -> PASS (no-token receipt stays SUSPECT)
not has_evidence("SOURCE=0 MARCO=7 torc=1")                 -> PASS (inside-word/bare numbers refused)
has_evidence("EXIT=0") / ("RC=1") / ("rc=0") / ("exit code 3") / ("exit 0") -> PASS all
non-vacuity PASS: no-token=SUSPECT, EXIT=/RC=/rc=/exit-code-N clear, bare numbers refused
```

## Before/after SUSPECT counts (embedded, real)

```
$ python3 scripts/receipt_index.py   (before fix)  ->  suspects=43
$ python3 scripts/receipt_index.py   (after fix)   ->  receipts=1361 sdk=61 total=1422 suspects=43
$ diff <(before set) <(after set)                   ->  IDENTICAL SETS
```

Premise correction to the dispatch context (and to bksusp-suspect-triage.md's
framing): the EXIT=/RC=/rc=N invisibility applied exactly to BK-SUSP's 10
class-(a) files, which BK-SUSP already normalized to `exit N` — by the time
this lane ran, the residual 43 carry no `EXIT=`/`RC=`/`exit`/`rc` token in any
spelling (verified by grep sweep over all 43 files: zero matches). They are
genuinely token-free receipts: real embedded output (witness transcripts,
`BACKUP_OK len=…` assertions, bench tables) that never recorded an exit status.
Clearing them requires the triage's re-witness prescription, not a regex
change. The regex fix still stands as the permanent guard: the next receipt
written as `RC=0` is no longer typed SUSPECT-PERMANENT.

## Residual SUSPECT set (43, genuinely token-free) with owners

Owner: coordinator re-witness wave (re-run each receipt's named
Replay/witness command with `; echo exit=$?` embedded), except as noted:

- kd-row witnesses → **kd-registrar** (kd24, kd25, kd26, kd27, kd29, kd30,
  kd31, kd32, kd85; re-witness = re-run the named probe, flip via
  `scripts/kd_flip.py --apply` where receipt-gated): kd24-double-slash-put,
  kd25-shape-gate, kd26-lro-terminal, kd27-metadata-authority,
  kd29-arm-vnet-links, kd30-arm-locations, kd31-arm-list-by-rg,
  kd32-arm-rg-patch, kd85-sb-enqueued-time-annotation
- stale/disposition rows (no re-witness; close via successor receipts per
  triage class (c)): 06-blob-x-ms-date-unvalidated, i29-court-x2-final,
  kd116-sb-session-delivery-shape-tbd,
  k8-tail-rows-dispositions-kd114-115-116, w6p-table-storage
- cost/analysis receipts (coordinator decides: re-witness vs retire):
  cost3-egress-quantification, cost4-migration-displacement
- the remainder (coordinator re-witness wave): bench-02, bench-03, bench-04,
  bench-05, c8-chaos-cross, errc4-hdr, lc1-8hop-tax-chain,
  otp29-capability-probes, powl2-wave-skeptic, scvd-backpressure-audit,
  w30-health-probe-pattern, w32-api-conformance, w6a, w6ab, w6ac, w6an, w6ao,
  w6aq2, w6be, w6l, wasm-memory-cdp-witness, bk59-warnings-recensus,
  bk81-lanes-v73, bklanaud-inflight, bkports-hygiene, bkports2-reconcile,
  kdim-ifmatch-row

## Files committed (explicit paths)

- `scripts/receipt_index.py`
- `docs/jira/v26.10.14/RECEIPTS.md` + `receipts/INDEX.md`
- `docs/jira/v26.10.16` .. `v26.10.22` (×2 each): regenerated RECEIPTS.md +
  receipts/INDEX.md for every window (generator's own diff)
- this receipt

## Falsifier

1. `grep -n "RC\\\\s\\*=" scripts/receipt_index.py` shows the added patterns.
2. Scratch probes above still pass (no vacuous widening: `SOURCE=0`/`MARCO=7`
   do not match; a token-free receipt stays SUSPECT).
3. `python3 scripts/receipt_index.py` is idempotent on a clean tree and
   reports `suspects=43`; if the residual 43 ever contain an EXIT=/RC=
   spelling, this receipt's premise correction is REFUTED.
