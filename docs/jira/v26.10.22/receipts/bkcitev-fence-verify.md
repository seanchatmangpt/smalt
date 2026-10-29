# BK-CITEV — post-integration citation-fence verify

**Standing:** **ALIVE**

Context: solo

Date: 2026-10-22. Read-only verify lane over the BK-CITEG citation fence
(`scripts/kd_receipt_fence.py` milestone-docs leg) on the current shared tree,
plus post-integration non-vacuity on a scratch copy. Zero doc/lib/register
edits on the shared tree.

## (1) Fence on the current tree — exit 0

```
$ python3 scripts/kd_receipt_fence.py
SKIP  docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md:17  docs/jira/v26.10.22/receipts/ttv5-store-partitioning.md  (typed gap on the citing line)
SKIP  docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md:21  docs/jira/v26.10.22/receipts/fr-snc-005.md  (typed gap on the citing line)
SKIP  docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md:24  docs/jira/v26.10.22/receipts/bk44-witness-all.md  (typed gap on the citing line)
SKIP  docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md:26  docs/jira/v26.10.22/receipts/bk35-head-court-sweep.md  (typed gap on the citing line)
SKIP  docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md:27  docs/jira/v26.10.22/receipts/ttv7b-quiesced-flip.md  (typed gap on the citing line)
SKIP  docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md:28  docs/jira/v26.10.22/receipts/bk53-finalrelease-seal.md  (typed gap on the citing line)
kd-receipt-fence: checked 735 receipt cites across 6 registers + 2 pattern docs + 5 milestone docs (406 cites, 6 typed-gap skips) -> OK
exit=0
```

## (2) Non-vacuity on a scratch copy — fence flips OK → FAIL, restores byte-exact

Scratch = `cp -R docs scripts gates` into `/tmp/bkcitev-scratch` (real fence,
real docs; deleted after — `rm -rf /tmp/...` was permission-denied in this
session, so the scratch dir remains on disk at `/tmp/bkcitev-scratch` with
byte-exact-restored content; coordinator may reclaim it).

```
== BEFORE ==
$ python3 scripts/kd_receipt_fence.py   # in scratch
exit=0
kd-receipt-fence: checked 735 receipt cites across 6 registers + 2 pattern docs + 5 milestone docs (406 cites, 6 typed-gap skips) -> OK

== SHIM (phantom) ==    # sed: receipts/bkprdr-prd-matrix.md -> receipts/bkcitev-PHANTOM.md at docs/jira/v26.10.22/PRD.md:64
$ python3 scripts/kd_receipt_fence.py
MISS  docs/jira/v26.10.22/PRD.md:64  receipts/bkcitev-PHANTOM.md
kd-receipt-fence: checked 735 receipt cites across 6 registers + 2 pattern docs + 5 milestone docs (406 cites, 6 typed-gap skips) -> FAIL
exit=1

== RESTORE ==
$ sed back; cmp /Users/sac/smalt/docs/jira/v26.10.22/PRD.md <scratch>/PRD.md
RESTORE byte-exact
exit=0 (fence -> OK)
```

A gate that accepts the phantom exits 0 as VACUOUS; this one flips OK → FAIL
(exit 1), names the exact file:line, and restores to OK. Non-vacuous on the
post-integration tree.

## (3) Sibling gates on the tree

- `python3 scripts/kd_flip.py` (read-only dry run, no `--apply`) → exit 0,
  `FLIP-ELIGIBLE: 0`, `FLIP-PENDING-WITNESS: 1` (KD-168 registrar hold).
  Note: there is no `--check` flag; read-only = bare invocation.
- `just docs-dod-check` → exit 0, fence leg
  `... 737 receipt cites ... (406 cites, 6 typed-gap skips) -> OK`
  (737 vs 735 in the standalone run: two more receipts landed on disk between
  the two runs — cite-count drift from concurrent lanes, both runs OK).
- `just receipt-index` → exit 0. **Disclosure / side effect reverted:** this
  recipe REGENERATES `RECEIPTS.md` + `receipts/INDEX.md` for v26.10.21 and
  v26.10.22, sweeping other in-flight lanes' uncommitted receipt files into
  the generated tables (301 → 326 receipt count in the diff). Per BK-CITEG's
  own scope note this is coordinator-at-integration only; I `git restore`d
  the four generated files to HEAD immediately (v26.10.21 pair were
  byte-identical regenerations, v26.10.22 pair reverted). The exit-0 signal
  stands; the generated files are untouched in the tree. Coordinator should
  rerun `just receipt-index` at integration as usual.

## (4) Verdict

Both legs hold: fence exit 0 on the live tree, and non-vacuity witnessed
post-integration (phantom → named MISS + exit 1 → byte-exact restore → OK).
Sibling gates exit 0. **ALIVE.**
