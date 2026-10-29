# BK-SUSP — receipt-index SUSPECT triage (53 → 43)

- **Standing**: PARTIAL_ALIVE — 10 of 53 SUSPECT flags cleared by content-preserving
  format normalization; remaining 43 triaged and typed below, clearable only by
  re-witness or successor receipts, not by reformatting.
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-SUSP

## Method

`python3 scripts/receipt_index.py` run twice (before/after), full outputs captured.
SUSPECT = `has_evidence/1` false: the receipt text contains none of the extractor's
evidence tokens (`exit N`, `N tests/examples/probes/checks`, `N passed`,
`N failures`, bare `pass`/`fail`/`skip`, `[ok]`, `verdict PASS/FAIL`).
Standing extraction was NOT the failure mode here — every one of the 53 had a
correctly extracted standing line, so the BK-JAR-style `**Standing:**` colon fix
had no applicable rows.

## Before/after counts (embedded, real)

```
$ python3 scripts/receipt_index.py | grep -c SUSPECT
53    (before)
43    (after)
```

Cleared exactly the 10 edited files (comm diff of SUSPECT sets confirms; no
other rows moved).

## Class (a) — fixed: extractor-spelling normalization of an already-recorded exit status

Each file already embedded the true exit token in a spelling the regex misses
(`EXIT=0`, `RC=0`, `rc=N` — the pattern requires a space after `exit`). Fix =
spell the same fact in extractor-visible form; no content claims touched:

| file | edit |
|---|---|
| v26.10.14/receipts/c4-kv-cosmos.md | `rc=0` → `rc=0 (exit 0)` |
| v26.10.19/receipts/kd119-kv-rs256-double-hash-tbd.md | `rc=1` → `rc=1 (exit 1)` |
| v26.10.20/receipts/w6ad-activity-log.md | `rc=0` → `rc=0 (exit 0)` |
| v26.10.20/receipts/w6ag-queue-update-message.md | `EXIT=0` → `exit 0` |
| v26.10.20/receipts/w6ai-cosmos-feed-options.md | `RC=0` → `RC=0 (exit 0)` |
| v26.10.20/receipts/w6aj-sb-arm-management.md | `RC=0` → `RC=0 (exit 0)` |
| v26.10.20/receipts/w6ap-metric-alerts.md | `EXIT=0` → `exit 0` |
| v26.10.20/receipts/w6au2-eh-throttle.md | `RC=0` → `RC=0 (exit 0)` |
| v26.10.20/receipts/w6bh-quota-usage.md | `EXIT=0` ×2 → `exit 0` |
| v26.10.20/receipts/w6bm-resource-health.md | `RC=0` ×2 → `exit 0` |

## Class (b1) — SUSPECT-PERMANENT (regex-invisible, but NOT evidence-free)

31 receipts carry real, often fenced, embedded output (witness transcripts,
`F*=ok` face lists, bench tables, wire captures) that contains none of the
extractor's tokens, and no content-preserving edit can make it token-visible
without minting an unrecorded claim (e.g. an exit status that was never written
down). These are NOT fabricated-evidence cases — the evidence is real and on
disk in the receipt; the flag is a regex-vocabulary limitation. Typed loudly
here rather than "fixed" by evidence-minting. Re-witness prescription for every
row: re-run the receipt's own named Replay/witness command with `; echo exit=$?`
embedded, then the flag clears mechanically.

Owner: coordinator (re-witness wave), except kd-row witnesses → kd-registrar.

Rows: bench-02, bench-03, bench-04, bench-05, c8-chaos-cross, errc4-hdr,
lc1-8hop-tax-chain, i29-court-x2-final (see class c), kd116 (see class c),
kd24, kd25, kd26, kd27, kd29, kd30, kd31, kd32, kd85, otp29-capability-probes,
powl2-wave-skeptic, scvd-backpressure-audit, w30-health-probe-pattern,
w32-api-conformance, w6a, w6ab, w6ac, w6an, w6ao, w6aq2, w6be, w6l, w6p (see
class c), wasm-memory-cdp-witness, bk59-warnings-recensus, bk81-lanes-v73,
bklanaud-inflight, bkports-hygiene, bkports2-reconcile, kdim-ifmatch-row.

## Class (c) — stale / superseded-disposition rows (no reformat; successor noted)

| receipt | disposition | successor / note |
|---|---|---|
| 06-blob-x-ms-date-unvalidated.md | typed UNSUPPORTED disposition (decision receipt, no run output by design) | docs/WIRE_PARITY.md row is the evidence-of-record |
| i29-court-x2-final.md | UNPARSED court-x2 artifacts from v26.10.18 | superseded by v26.10.22 full-green HEAD sweep (bkseal receipt, commit 278c7141) |
| kd24/25/26/27-*-witness.md | OBSOLETE stale-row dispositions with embedded wire output; rows receipt-gated for kd_flip | kd-registrar flips rows via `scripts/kd_flip.py --apply`; re-witness = re-run the receipt's named probe |
| kd29/30/31/32-*-witness.md | same OBSOLETE-disposition family (K5) | same as above |
| kd116-sb-session-delivery-shape-tbd.md | UNKNOWN register stub; evidence-of-record is `sdk-results/wf3-ts-messaging-eventing.md` | closes when the session-settle falsifier runs |
| w6p-table-storage.md | 502-byte stub; table router audited in 06-blob post-close note + w6bk | re-witness = table legs probe |
| k8-tail-rows-dispositions-kd114-115-116.md | disposition of 114/115/116; per-row evidence lives in the kd115/116 receipts | closes with kd115/116 |

## Deferred (in-flight-lane conflicts)

No receipt files were dirty at lane start (dirty set was KNOWN_DIVERGENCES ×2,
PRD.md, justfile.d/12-docs-dod.just, workspace/* — other lanes), so no receipts
were skipped. bklanaud-inflight.md was committed (f28d9ca5) before my lane
started; my edits touch it not.

**Collision disclosure (same-checkout fan-out)**: the coordinator's tick
checkpoint commit 860261c9 ("in-flight snapshots … BK-SUSP, owners hold their
files") landed mid-lane and carries the 10 class-(a) receipt edits; my own
commit 29f96c43 carries only this receipt. Net tree state is correct — both
are on main; attribution is split across the two commits by the collision,
not by lane ownership.

## Left unstaged for coordinator

`receipt_index.py` regenerated RECEIPTS.md + receipts/INDEX.md for 8 milestone
windows (deterministic projection of the 10 edited receipts + this receipt).
Task scope said commit receipts only — left uncommitted for coordinator
integration.

## Falsifier

Re-run `python3 scripts/receipt_index.py | grep -c SUSPECT` — returns 43, not 53,
and the 10 class-(a) files are absent from the list. If any edited receipt
reappears, this receipt is REFUTED.
