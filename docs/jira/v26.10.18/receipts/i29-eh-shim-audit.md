# Receipt — i29 EH shim-marker audit (event_hubs.ex SHIM-COURT markers)

- **Subject:** `/Users/sac/smalt` @ main, working tree; `lib/smalt/messaging/event_hubs.ex` (clean vs HEAD; last commit touching it: 9c74de3 2026-10-17 21:37 -0700)
- **Standing:** PARTIAL_ALIVE (3 covered / 1 orphaned)
- **Context:** solo(lib/smalt/messaging/event_hubs.ex marker audit, kd_flip dry-run, docs/jira grep, host)
- **Date:** 2026-10-18

## Scope

All four `SHIM-COURT` markers in `lib/smalt/messaging/event_hubs.ex` (:136, :145, :225, :240). Audit questions: (a) named KD row / receipt covering the marker id; (b) witness receipt mtime vs shim lineage (kd_flip law: witness newer than shim). Read-only audit — no flips, no lib edits.

## Verification (2026-10-18, unedited output)

```
$ grep -n "SHIM-COURT" lib/smalt/messaging/event_hubs.ex
136:         # SHIM-COURT / audit-A22-F1: a single legal AMQP message may carry
145:         # SHIM-COURT / R141 (W5-10 exploit): a tail group with NO body section
225:    # SHIM-COURT / R185e (replaces R166): a pre-body section whose KIND is
240:      # SHIM-COURT / R166 homogeneity: every completed group must match the
```

```
$ git log -1 --format="%h %ad %s" -- lib/smalt/messaging/event_hubs.ex
9c74de3 Sat Oct 17 21:37:57 2026 -0700 fix(fences): cite-drift re-anchor (fence-10 line shift) + regen residue + i21 repair wave receipts
```

```
$ git status --short lib/smalt/messaging/event_hubs.ex
(empty; exit 0 — working tree matches HEAD)
```

```
$ grep -rn "A22-F1" docs/ --include="*.md"
(no matches, exit 1)
```

```
$ python3 scripts/kd_flip.py | grep KD-53
  KD-53: [CLOSED-SIMULATED] lib/smalt/egress_router.ex, lib/smalt/messaging/event_hubs.ex
```

```
$ stat -f "%Sm  %N" <key files>
Oct 18 22:33:54 2026  lib/smalt/messaging/event_hubs.ex
Oct 15 22:31:45 2026  docs/jira/v26.10.14/receipts/2026-10-15-kd53-eh-batch-witness.md
Oct 16 03:19:32 2026  docs/jira/v26.10.16/receipts/r141-eh-batch-body-discriminator.md
Oct 16 03:21:03 2026  docs/jira/v26.10.16/receipts/r166-eh-discriminator-dead-clause.md
Oct 16 03:19:24 2026  docs/jira/v26.10.16/receipts/r185e-eh-batch-dup-kind.md
```

Note: the shim file's Oct 18 22:33 mtime is a shim-court touch-and-restore artifact — content is byte-identical to HEAD (clean `git status`), disclosed in `azb-16-amqp-saturation.md` ("held a SHIM-COURT (KD-53, batch-split disabled)... restore byte-exact"). The landed shim lineage is commit d02c241 (2026-10-16 20:24 -0700).

## Per-marker verdicts

| marker | id | covered row | witness receipt (mtime) | verdict |
|---|---|---|---|---|
| :136 | audit-A22-F1 | none — zero occurrences of "A22-F1" anywhere in docs/ | none | **ORPHANED** — missing both a KD row and a witness receipt |
| :145 | R141 (W5-10) | KD-53 (docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:221, CLOSED-SIMULATED) | r141-eh-batch-body-discriminator.md, PASS (Oct 16 03:19) — notes supersession by R185e | COVERED (witness predates d02c241 landing; KD-53 row's named witness is the Oct 15 kd53 batch witness) |
| :225 | R185e (replaces R166) | KD-53 (same row) | r185e-eh-batch-dup-kind.md, PASS 26/0 + shim-courts exit 0 (Oct 16 03:19) | COVERED (same mtime caveat) |
| :240 | R166 homogeneity | KD-53 (same row) | r166-eh-discriminator-dead-clause.md, PARTIAL_ALIVE (Oct 16 03:21) — superseded by R185e | COVERED via supersession |

## Orphaned detail — audit-A22-F1 (:136)

The only occurrence of the token "A22-F1" in the entire repo is the marker itself (`grep -rn "A22-F1" docs/` exit 1). Missing:

1. A `KD-nn` row in `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (or the active window's register) naming A22-F1, and
2. A witness receipt with real probe output for the multi-data-section split heuristic (:136-:144).

The behavior itself (multi-data-section AMQP message split-when-all-inners-complete) is plausibly within KD-53's close condition, but no row names the marker id, so per the register law it is a coverage cell without a named row: ORPHANED. Remedy is registrant action (add the row + witness), not a flip.

## Bound

No flips performed; no register rows added, edited, or renumbered; no lib edits. kd_flip dry run reports KD-53 CLOSED-SIMULATED — unchanged by this audit.
