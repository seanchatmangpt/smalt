# BK-SUSP5 — final SUSPECT sweep (receipt_index evidence tokens)

**Standing:** ALIVE — 9/9 targeted receipts cleared (receipt_index suspects 9 → 1 residual, individually typed with owner below); witness-window real NO-STANDING failures 2 → 0.
Context: solo
Date: 2026-10-22 ~09:00–09:10 PDT
Repo: /Users/sac/smalt (canonical checkout; no git state commands)
Lane: BK-SUSP5

## Before (embedded)

```
$ python3 scripts/receipt_index.py
receipts=1554 sdk=61 total=1615 suspects=9
  SUSPECT: bkaud2-lane-accounting.md (standing ALIVE)
  SUSPECT: bkbmir-jsonl-mirrors.md (standing ALIVE)
  SUSPECT: bkbmir2-mirror-wave2.md (standing PARTIAL_ALIVE)
  SUSPECT: bkclean3-reclaim.md (standing ALIVE)
  SUSPECT: bkdrain-monitor.md (standing ALIVE)
  SUSPECT: bkdrain2-monitor.md (standing ALIVE)
  SUSPECT: bkmcpsha-sha-fix.md (standing ALIVE)
  SUSPECT: bkp20-export-disposition.md (standing UNSUPPORTED)
  SUSPECT: bkqmon-window.md (standing UNKNOWN)
```

Root cause: all 9 carried Standing lines already — they were SUSPECT because
`has_evidence` found zero evidence tokens (exit status / PASS / counts) in
the whole text. Diagnosis, not standing, was the gap.

## Method

Chicago re-verification: for each receipt, one real checkable claim from its
embedded output was re-run fresh at ~09:03 PDT, and the actual command +
output + exit status appended as an "Evidence re-check (BK-SUSP5)" block.
No standing value was altered except bkqmon-window (see below). All 9
re-checks passed on the real substrate:

- bkaud2: anchor receipts + `_LANES.md` BK-AUD2 section on disk, ls/grep exit 0.
- bkbmir: 11 whitepaper artifact sha256s re-hashed, diff vs recorded = exit 0 (11/11).
- bkbmir2: all 21 recorded mirror sha256s confirmed present+equal among the
  47 jsonls now under `docs/jira/v26.10.2{0,1,2}/bench/` (26 mirrors landed
  post-receipt from other lanes — superset, no conflict; one MISS in the
  first pass was my own heredoc transcription typo, corrected on disk: the
  on-disk `cdd5e23d…` matches the receipt byte-for-byte).
- bkclean3: 7 sampled reclaimed `_build-*` roots confirmed absent (exit 0).
- bkdrain: "landed since checkpoint" receipts (bkxprif, bkmon2) on disk (exit 0).
- bkdrain2: receipts dir 388 > 333 census figure (drain trajectory holds).
- bkmcpsha: on-disk descriptor sha256 = receipt-recorded `5c9446bd…` (exit 0).
- bkp20: restored `next.config.mjs` sha256 = receipt-recorded `61d434ed…`
  (exit 0); UNSUPPORTED disposition stands.
- bkqmon-window: uptime 09:03 load 39.01/16.24/10.60 (fell from ~90-98),
  three duckdb orphans drained (pgrep no match). 07:20
  BENCH-WINDOW-BLOCKED verdict stands as-written.

## Standing-line fix (bkqmon-window)

bkqmon-window was also a witness-window NO-STANDING ("Standing: SUSPECT →
verdict BENCH-WINDOW-BLOCKED" — SUSPECT/BENCH-WINDOW-BLOCKED are not
canonical tokens). The concurrent BK-STAND6 lane retyped it to a canonical
PARTIAL_ALIVE line while this lane ran (same-checkout fan-out; not my edit).
This lane's contribution to that receipt is the appended evidence re-check
only.

## After (embedded)

```
$ python3 scripts/receipt_index.py
receipts=1559 sdk=61 total=1620 suspects=1
  SUSPECT: bkstand6-final.md (standing PARTIAL_ALIVE)
```

## Residual typed (1, with owner)

- `bkstand6-final.md` — SUSPECT-PERMANENT-pending-landing, owner BK-STAND6.
  The file was written 68 s before this check (09:03:53, checked 09:05:01):
  the BK-STAND6 lane is actively in-flight and its receipt is not final.
  Per lane file ownership this lane did not edit it. Coordinator should
  re-run `receipt_index` after BK-STAND6 lands; if it remains
  evidence-token-less, the same one-command re-check pattern applies
  (BK-STAND6's own subject is standing lines, so its receipt's embedded
  edits are directly re-checkable via the receipts it names).

## Residuals appearing mid-lane (typed, with owners)

A re-run at ~09:08 (receipts=1564, suspects=3) surfaced three NEW suspects
from concurrent lanes landing while this sweep ran — none in the assigned
list, none edited by this lane:

- `bkclean4-reclaim.md` (owner BK-CLEAN4) — SUSPECT-pending-landing; same
  one-command re-check applies (sample a reclaimed root's absence, du census).
- `bkstand6-final.md` (owner BK-STAND6) — as typed above.
- `bkzombr-reap.md` (owner BK-ZOMBR) — SUSPECT-pending-landing; same
  pattern (re-run the reap verification command its census names).

These are in-flight receipts from active lanes, not this lane's residue:
each is individually typed with its owner and the exact closing check. The
assigned 9 are cleared with real embedded re-check output.

## Witness window

```
$ python3 scripts/witness_all.py --dry-run | grep -c NO-STANDING   (baseline, before)
3
$ python3 scripts/witness_all.py --dry-run | grep NO-STANDING      (after)
[WITNESS-DRY] docs/jira/v26.10.22/receipts/bkwparse-hardening.md class=readonly cmd=grep -c 'WITNESS-FAIL.*NO-STANDING' (standing: PARTIAL_ALIVE)
```

Real [WITNESS-FAIL] NO-STANDING failures: baseline 2 (bkgwsp-poll,
bkqmon-window) → 0. The one remaining grep hit is not a failure — it is
bkwparse-hardening's own rerunnable probe command containing the literal
search string (BK-WPARSE probe class preserved, non-vacuous).

## Falsifier

Re-running `python3 scripts/receipt_index.py` after BK-STAND6 lands shows
suspects=0; a re-run now showing any of the 9 cleared receipts back in the
SUSPECT list refutes this receipt.
