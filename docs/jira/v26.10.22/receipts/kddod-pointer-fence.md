# KD-DOD — KD-169 evidence pointer repair + KD register receipt-cite fence

**Standing:** ALIVE
Context: solo
Date: 2026-10-22
Lane: KD-DOD

## Change

1. **KD-169 evidence pointer fixed in both registers.** The row cited
   `receipts/expl4r-wirefront-repairs.md`, which does not exist on disk
   (KD-MIRROR flagged, receipt `kdmirror-canonical-sync.md`). The real
   witnessing receipt is `wps-exp4-repairs.md` (WPS-EXP4, "F5 — unauthenticated
   server faces", which explicitly names KD-169 as the registration outcome of
   F5 and the F1 token-verify fail-close). Fixed in:
   - `docs/jira/v26.10.22/KNOWN_DIVERGENCES.md` (window doc, KD-169 bullet)
   - `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (canonical table row)

   The finding-origin cite `expl4-wirefronts-errc.md` was already correct and
   is retained. Checked sibling exp4 receipts on disk: `wps-exp4-repairs.md`
   (witnesses KD-169), `wire-exp4-frame-decoder.md` (AMQP F2, not KD-169),
   `kafka-exp4-repairs.md` / `bkkwt-expl4-req-fix.md` (Kafka faces, not
   KD-169), `expl4-wirefronts-errc.md` (finding origin) — only wps-exp4
   witnesses the row's faces.

2. **Fence extended: `scripts/kd_receipt_fence.py` + docs-dod integration.**
   Extracts every receipt path cited in KD register table rows (`| KD-nn |`)
   across all six `docs/jira/*/KNOWN_DIVERGENCES.md` registers and verifies
   existence, fail-closed with the offending row id. Path resolution: `docs/`
   -prefixed cites resolve against repo root; bare `receipts/...` cites
   resolve against the register's own directory. Wired into
   `justfile.d/12-docs-dod.just` (`docs-dod-check`), so a phantom KD-table
   evidence cite now fails the docs DoD gate.

   Fence triage while bringing the real tree green surfaced **5 more phantom
   cites of the same class** (fixed same commit, fix-forward):
   - KD-24 `kd24-providers-witness.md` -> `kd24-double-slash-put-witness.md`
   - KD-25 `kd25-sku-witness.md` -> `kd25-shape-gate-witness.md`
   - KD-26 `kd26-lro-witness.md` -> `kd26-lro-terminal-witness.md`
   - KD-27 `kd27-metadata-witness.md` -> `kd27-metadata-authority-witness.md`
     (all four: wrong filename in the CLOSED-OBSOLETE witness cite; real
     receipts verified on disk under `docs/jira/v26.10.20/receipts/`)
   - KD-129 bare `receipts/kd88-attach-race-witness.md` ->
     `docs/jira/v26.10.20/receipts/kd88-attach-race-witness.md` (bare cite
     resolved against the canonical register's directory; the file lives in
     the v26.10.20 window)

   KD-126's `popcorn_demo/receipts/...` cite is NOT a miss (submodule-relative
   path, exists); the fence regex uses a `\w./-` lookbehind boundary so it is
   not false-positived. KD-174's `az1c-kafka-receipt.md` cite is declared
   "(in-flight, BK-122r)" by the row itself — the fence prints a loud SKIP
   for in-flight-declared rows rather than a silent pass or false MISS; when
   BK-122r lands, the row loses the marker and the fence starts enforcing.

## Embedded fence proof (as run)

Non-vacuity: phantoms reintroduced on a scratch copy of the registers
(phoenix: KD-169 expl4r cite + KD-24 wrong filename), fence run against the
scratch tree:

```
$ python3 $T/scripts/kd_receipt_fence.py   # scratch, phantoms reintroduced
MISS  KD-24  docs/jira/v26.10.14/KNOWN_DIVERGENCES.md: docs/jira/v26.10.20/receipts/kd24-providers-witness.md
MISS  KD-169 docs/jira/v26.10.14/KNOWN_DIVERGENCES.md: docs/jira/v26.10.22/receipts/expl4r-wirefront-repairs.md
...   (each scratch-tree cite MISSING because the scratch carries no receipts;
       fence exit=1)
kd-receipt-fence: checked 252 receipt cites across 1 registers -> FAIL
fence-exit=1
```

Post-fix, real tree:

```
$ python3 scripts/kd_receipt_fence.py
SKIP  KD-174  docs/jira/v26.10.14/KNOWN_DIVERGENCES.md: cite declared (in-flight) by the row itself
kd-receipt-fence: checked 306 receipt cites across 6 registers -> OK
fence-exit=0

$ just docs-dod-check   (tail)
OK    README.md
SKIP  KD-174  docs/jira/v26.10.14/KNOWN_DIVERGENCES.md: cite declared (in-flight) by the row itself
kd-receipt-fence: checked 306 receipt cites across 6 registers -> OK
docs-dod-exit=0

$ python3 scripts/kd_flip.py   (read-only)
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 1
  KD-171: no post-shim receipt newer than shim mtime (2026-10-22T04:54:37)
WITNESS-AMBIGUOUS: 1 — flip refused, disambiguate with --witness KD-ID=PATH:
  KD-168: 3 post-shim receipts carry close evidence ... (typed refusal, no flip)
kd-flip-exit=0
```

## Standing

ALIVE — fence exits 1 on reintroduced phantoms (scratch proof), exits 0 on the
repaired tree; docs-dod-check green with the fence wired in; kd_flip read-only
green (no flip performed, KD-171 pending-witness and KD-168 witness-ambiguous
are pre-existing typed-refusal states, not introduced).
