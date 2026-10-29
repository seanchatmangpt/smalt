# BK-150 — finisher sweep: landed-but-uncommitted receipts + fleet audit (v26.10.22)

**Standing:** PARTIAL_ALIVE
Context: full
Date: 2026-10-22
Head: 17848b75 (main, working tree CLEAN)

## Result

No uncommitted receipts. Every file under
`docs/jira/v26.10.22/receipts/` (99 files) is tracked and committed;
`git status --porcelain` is empty; zero untracked files under
`docs/jira/v26.10.22/`. The coordinator checkpoint chain
(17848b75 ← 8475ca49 ← f240f058 ← 4e1bbde5 ← 08401335 ← d93e803a ← 6ef3fb42
← 23823584 …) swept all landed work as intended.

## Per-lane status, BK-106..150

Landed = receipt file committed. Folded = landed as fold into a register/doc,
no standalone receipt file. Missing = no receipt and no fold found on disk.

| Lane | Status | Evidence (path or disposition) |
|---|---|---|
| BK-106 | landed | `receipts/bk106-sync-engine-fixes.md` (ALIVE) |
| BK-107/107b | landed | `receipts/bk107-wsrelay-combined.md`, `bk107b-ind-fold.md` |
| BK-108 | landed | `receipts/bk108-census-kdconf.md` |
| BK-109/109b | landed | `receipts/bk109-kd165-pointer.md`, `bk109b-g2-telemetry.md` |
| BK-110 | landed | `receipts/bk110-a7-disposition.md` |
| BK-111 | landed | `receipts/bk111-provo-agent-chain.md` (ALIVE; closes W3C GAP-6a half) |
| BK-112 | landed | `receipts/bk112-kd88-153.md` |
| BK-113 | landed | `receipts/bk113-rdfstar-probe.md` (GAP-1a/4a falsifier probe) |
| BK-114 | landed | `receipts/bk114-verification-reruns.md` |
| BK-115b | landed | `receipts/bk115b-trip-regression.md` |
| BK-116 | missing | no receipt, no doc mention found |
| BK-117b | landed | `receipts/bk117b-typed-exit.md` |
| BK-118 | landed | `receipts/bk118-useasyncfn-port.md` |
| BK-119 | missing/429-killed | "PR branch" cited in checkpoints only; no branch on origin (`git branch -a`: main only), no doc trace |
| BK-120/121 | 121: doc-mention only (az-command-corpus.md); 120: missing | no receipts |
| BK-122r | in-flight→checkpointed | named in checkpoints (kafka probes); no receipt file |
| BK-123 | doc-mention only (az-command-corpus.md) | no receipt |
| BK-124 | missing | no trace |
| BK-125..128 | landed | `bk125-sync3-` / `bk126-spof4-` / `bk127-spofb-` / `bk128-kd167-reconcile.md` (all ALIVE) |
| BK-129rr | landed | `receipts/bk129rr-pplan-agent-chain.md` (PASS 10/10; closes W3C GAP-6a with BK-111) |
| BK-130 | landed | `receipts/bk130-hook-ports.md` (PASS) |
| BK-131 | landed | `receipts/bk131-e2e-rerun.md` (ALIVE) |
| BK-132 | doc-mention only (pillars-cross-industry.md ×5) | no receipt |
| BK-133 | missing | no trace |
| BK-134 | doc-mention only — pillars doc cites "BK-134 spec UNCOMMITTED... PILLAR-SPEC-ABSENT" | no receipt |
| BK-135 | checkpoint-queued (mass-429 list) | no receipt |
| BK-136/137 | checkpointed (pillar gates in-flight) | no receipts |
| BK-138 | checkpointed (react-use PR) | no receipt |
| BK-139r | landed | `receipts/bk139r-kd166-fold.md` (KD-166 → KD-170 renumber, zero kd_flip skew) |
| BK-140/141 | checkpointed | no receipts |
| BK-142/142r | folded | `pillars-cross-industry.md` (PARTIAL_ALIVE disk-truth fold, 3e8baf0f / da0a434c) |
| BK-143rr | landed | `receipts/bk143rr-aero-p3.md` (ALIVE); gate `070_proposer_judge.rq` verified on disk in `~/ggen-marketplace/packs/industry-aero-defense/gates/` |
| BK-144 | missing | no trace |
| BK-145/145b | folded | mass-429 checkpoint 23823584 (pillar-matrix disk-truth fold, aero P3 = sole open cell at fold time) |
| BK-146r | landed | `receipts/bk146r-pillar-consumers.md` (IND-2/4 consumer sync; names 070 landed via BK-143rr) |
| BK-147 | missing | no trace |
| BK-148 | folded | `W3C-FORMALIZATION.md` GAP ledger final (8475ca49): GAP-6a CLOSED, GAP-1a/4a UPSTREAM-OPEN, disposition ledger + typed flip rule |
| BK-149 | missing/429-killed | "smalt-cli closeout" named in checkpoints only; no receipt, no doc trace, no branch |
| BK-150 | this receipt | — |

Tally: 30 landed/folded, 1 folded-ledger (148), 6 doc-mention-only
(120/121/122r/123/132/134), 8 missing with zero trace
(116/124/133/144/147 + 119/149 killed-by-429, relaunch queued), 5 in-flight
checkpointed (135/136/137/138/140/141). (Ranges overlap; table is ground
truth.)

## Gaps for coordinator

1. **Stale pillars cell**: `pillars-cross-industry.md` line 45 + notes at
   lines 102/110-111 still declare aero P3 "in-flight (BK-143r) ... no
   receipt in either repo". BK-143rr receipt landed (d93e803a) and the gate
   is committed in ggen-marketplace — per the doc's own flip rule, the aero
   P3 cell and "sole open cell" line should flip to landed.
2. **Zero-trace lanes** (never relaunched post-429): BK-116, BK-124,
   BK-133, BK-144, BK-147 — no receipt, no checkpoint name, no doc mention.
   Relaunch or retire explicitly.
3. **BK-119 / BK-149** cited as "finishing" in 17848b75 but no branch, no
   receipt — relaunch queue should treat them as not-started.
4. `INDEX.md` header says "99 files" and flags `bk81-lanes-v73.md` SUSPECT —
   this receipt file itself is now the 100th; `just receipt-index` rerun +
   `just docs-dod-check` are owed at next checkpoint.
