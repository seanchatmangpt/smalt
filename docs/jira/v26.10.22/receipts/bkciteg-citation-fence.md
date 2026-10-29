# BK-CITEG — milestone-doc citation fence (dual-base + typed-gap skip)

**Standing:** **ALIVE**

Context: solo

Date: 2026-10-22. Census of every receipt/path citation in the 5 milestone
PRD/VALIDATION/FINAL-RELEASE docs, then a fence extension so the
citation-drift class fixed by BK-ARD21B / BK-NFRV / BK-NFRD1 cannot reopen.
No lib/, test/, or register edits. Docs unchanged — zero genuinely broken
citations found on disk today.

## (1) Census — 464 cites, 458 resolve dual-base, 6 typed-expected, 0 broken

Extraction regex: path-like cites (prefixes `docs/ scripts/ gates/ test/ lib/
receipts/ tmp/`) ending in `md|py|exs|sh|jsonl|json|ttl|txt|mjs|log`, resolved
dual-base (milestone dir first for bare paths, then repo root; `docs/`-prefixed
against repo root). Full per-cite log: 464 cites over the 5 docs, 458 OK.

Real gate-row receipts resolve, e.g.:

```
OK   docs/jira/v26.10.21/PRD.md:68   [milestone]  receipts/cas412r-postfix-regression.md
OK   docs/jira/v26.10.21/PRD.md:138  [milestone]  receipts/bk31-gws14-inwasm-courts.md
OK   docs/jira/v26.10.21/VALIDATION.md:11   [milestone]  receipts/powlbench-fresh-rerun.md
OK   docs/jira/v26.10.21/VALIDATION.md:118  [root]       test/internal/vm_zero_growth_test.exs
OK   docs/jira/v26.10.21/VALIDATION.md:118  [milestone]  receipts/impl18-vm-census-processiter-adoption.md
```

The 6 non-resolving cites are all in `FINAL-RELEASE-26.10.22.md` and all are
expected receipts the doc's own gate ledger types as future work — matching
BK-10b's audit finding that the same 6 are "EXPECTED — IN-FLIGHT/QUEUED/
PENDING-GATE":

```
MISS docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md:17  docs/jira/v26.10.22/receipts/ttv5-store-partitioning.md   (row: IN-FLIGHT, "expected receipt")
MISS docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md:21  docs/jira/v26.10.22/receipts/fr-snc-005.md                (row: QUEUED, "expected receipts")
MISS docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md:24  docs/jira/v26.10.22/receipts/bk44-witness-all.md          (row: PENDING-GATE, "expected green")
MISS docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md:26  docs/jira/v26.10.22/receipts/bk35-head-court-sweep.md     (row: PENDING-GATE, "expected")
MISS docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md:27  docs/jira/v26.10.22/receipts/ttv7b-quiesced-flip.md       (row: PENDING-GATE)
MISS docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md:28  docs/jira/v26.10.22/receipts/bk53-finalrelease-seal.md    (row: PENDING-GATE)
```

All 6 rows type the gap inline, so per the task's own rule ("typed, never
invented") they are typed-expected, not broken. Zero doc edits made.

## (2) Fence extension — `scripts/kd_receipt_fence.py`

Extended the existing KD register fence with `check_milestone_docs()`: scans
the 5 milestone docs (`SEAL_DOCS`, explicit list), extracts `receipts/`-class
cites via the fence's existing `RECEIPT_RE`, resolves dual-base (bare path →
milestone dir, then repo root; `docs/`-prefixed → repo root), and applies a
typed-gap skip: a citing line containing `IN-FLIGHT / QUEUED / PENDING-GATE /
"expected receipt" / "not on disk" / "absent"` renders a loud `SKIP` instead
of a `MISS` (same convention as the KD `(in-flight)` skip). Summary line now
reports the milestone leg explicitly:

```
kd-receipt-fence: checked 735 receipt cites across 6 registers + 2 pattern docs + 5 milestone docs (406 cites, 6 typed-gap skips) -> OK
```

Wiring: `just docs-dod-check` already runs `scripts/kd_receipt_fence.py`
(`justfile.d/12-docs-dod.just`, KD-DOD block), so the extension is gate-covered
with no justfile edit — lanes never edit the root justfile.

## (3) Non-vacuity court (shim on a scratch copy)

BASELINE / SHIM / RESTORE over a full `cp -R docs` scratch tree at
`/tmp/bkciteg-nonvacuity` (real fence, real docs, deleted after):

```
== BEFORE ==
exit=0
kd-receipt-fence: checked 735 receipt cites across 6 registers + 2 pattern docs + 5 milestone docs (406 cites, 6 typed-gap skips) -> OK
== SHIM (phantom) ==    # sed: bk75-kd-final-census.md -> bkciteg-PHANTOM.md in v26.10.22/PRD.md
exit=1
MISS  docs/jira/v26.10.22/PRD.md:80  receipts/bkciteg-PHANTOM.md
kd-receipt-fence: checked 735 receipt cites across 6 registers + 2 pattern docs + 5 milestone docs (406 cites, 6 typed-gap skips) -> FAIL
```

```
== RESTORE ==
restore byte-exact   (cmp)
exit=0
```

A gate that accepts the phantom exits 0 as VACUOUS; this one flips OK → FAIL
(exit 1) and restores to OK. Court is non-vacuous.

## (4) Gates after

- `just docs-dod-check` → exit 0 (its fence leg: `... + 5 milestone docs (406 cites, 6 typed-gap skips) -> OK`).
- Non-vacuity court above.

## Scope + disclosure

- Fence leg covers `receipts/`-class cites (the BK-ARD21B class). `tmp/bench/`
  scratch `.jsonl` cites in these docs resolve today (all 34 checked) but are
  transient by convention ("JSON receipts in tmp/ are scratch, not indexed",
  CLAUDE.md); durable mirrors exist under `docs/jira/v26.10.21/bench/` and
  `.../whitepaper/artifacts/` (PROVENANCE.md). Out of fence scope by design —
  a fence over gitignored scratch would false-fail on every future tmp clean.
- `just receipt-index` NOT run: it regenerates INDEX/RECEIPTS tables and would
  sweep other in-flight lanes' receipts; coordinator runs it at integration.
- Census regex caveat recorded: alternation must be `jsonl|json` — a `json`
  branch first truncates `.jsonl` cites and manufactures phantom misses
  (first census run reported 27 false MISSes from exactly that bug).
