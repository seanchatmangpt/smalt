# POWL 2.0 Wave — Milestone Documentation (T33DOC)

Compiled 2026-10-21 ~12:18 PT from disk receipts and live test runs on the
current tree. Standing: **PARTIAL_ALIVE — wave landing live during
documentation** (compiler.ex landed syntactically broken at 12:17:51 PT,
one minute before this doc's final read; shared `mix test` is in
compile-abort until its owner fixes or reverts it per the compile-freeze
SLA).

## Scope

POWL 2.0 execution chain: PetriNet primitives → reticle (Gate-1
admission) → decomposition/projection → compiler → executor kernel →
pplan receipt engine. All files under `lib/smalt/powl2/`,
`lib/smalt/powl2.ex`, `lib/smalt/pplan/`, `lib/smalt/petri_net.ex`;
tests in `test/internal/`.

## Per-gate status table

Disk evidence: receipt paths are under
`docs/jira/v26.10.20/receipts/`; "current-run" figures are this doc
lane's own runs at ~12:12–12:16 PT on `_build-doc33` (fresh lane build
root, offline). Claimed figures are from the named receipts/commit
message, cited as claimed.

| Gate | Module(s) | Files on disk | Witness receipt | Claimed | Current-run measured (12:12–12:16 PT) | Standing |
|---|---|---|---|---|---|
| Gate 1 — reticle (admission) | `Smalt.POWL2.Reticle` | `lib/smalt/powl2/reticle.ex` (mtime 12:08:57, **untracked in git**) | `powl2-wave-skeptic.md` (live-probe: cycle refusals typed, BFS terminates, "ALIVE by direct probe; UNWITNESSED at audit time") | 17/17 (commit 92e49af message) | 16/17 (1 failure: "refuses irreflexive violation", `powl2_reticle_test.exs:50`) | PARTIAL_ALIVE — re-author in flight → **PENDING-RETAUTH** |
| Receipt engine | `Smalt.PPlan.ReceiptEngine` | `lib/smalt/pplan/receipt_engine.ex` | `powl2-wave-skeptic.md` (merkle mutation suite: 6/6 TRUE incl. delta-sensitive step hash, empty-run sha256("") match; DETS record_step/seal_receipt path explicitly UNWITNESSED) | 6/6 (commit 92e49af message) | 6/6 (0 failures) | PARTIAL_ALIVE (merkle suite witnessed; DETS chain path unwitnessed per skeptic) |
| Primitives | `Smalt.PetriNet` | `lib/smalt/petri_net.ex` | none standalone (skeptic marked petri_net UNWITNESSED at audit time) | 18/18 (commit 92e49af message) | 18/18 (0 failures) | ALIVE (current run) |
| Executor kernel | `Smalt.POWL2.Executor` | `lib/smalt/powl2/executor.ex` | `powl9-executor-kernel.md` (7/7 on `_build-powl9`, two runs, flake-checked) | 7/7 | 7/7 (0 failures) | ALIVE — with the double-deletion incident disclosed in the receipt's Environment section (tree deleted twice ~11:58, re-authored to md5 239f1c42…) |
| Decomposition | `Smalt.Powl2.Decomposition` | `lib/smalt/powl2/decomposition.ex` (mtime 12:15:35 — rewritten during this doc's compilation) | none (skeptic: UNWITNESSED; "struct-expansion artifact in Code.compile_file harness only") | — | 0/4 measured at 12:12 run (4 failures: partition_sm diamond/choice/whole-diamond, validators concurrency-hiding) — but the file was rewritten at 12:15:35, so the 12:12 numbers are **stale by mtime** | IN-FLIGHT — 12:12 failures predate the 12:15 rewrite; no post-rewrite run exists |
| Projection | `Smalt.POWL2.Projection` | `lib/smalt/powl2/projection.ex` (untracked) | `powl3-projection.md` (8/8 on `_build-powl3` at 12:13 PT) | 8/8 | 8/8 (0 failures) | ALIVE |
| Compiler | `Smalt.Powl2.Compiler` (expected by `lib/smalt/powl2.ex` seam) | `lib/smalt/powl2/compiler.ex` (landed 12:17:51, **syntax error line 81**) | `powl2-wave-skeptic.md` HIGH-1/HIGH-2 refutations ran against md5 f8e5a21f… | — | compile-abort (SyntaxError `syntax error before: '@'` at compiler.ex:81:51) | BUILD_BROKEN — owner must fix or revert per compile-freeze SLA |
| Change feed | `Smalt.POWL2.ChangeFeed` | `lib/smalt/powl2/change_feed.ex` | none | — | 8/8 (0 failures, run at 12:16 PT) | ALIVE (current run), UNWITNESSED by receipt |

## OPEN items — skeptic HIGH findings (not closed)

Both findings are in `receipts/powl2-wave-skeptic.md` against compiler
md5 f8e5a21f358cfaa01466142a50e4cc45. They are OPEN: no closing receipt
exists, and the compiler has since been rewritten twice more (current
file does not even compile), so the findings describe an ancestor state —
they close only with a new receipt against the landed compiler.

- **HIGH-1 (court-critical): the compiler ADMITS the non-separable
  class.** The moduledoc's step-4 refusal (`{:error,
  :non_separable_fallthrough}`) never fired on the skeptic's
  concurrent+conflicting net; the SM branch emitted a ChoiceGraph with a
  bidirectional can-follow (POWL loop) face between truly concurrent
  blocks — concurrency silently re-modeled as a loop. Root shape:
  `concurrency_hiding?` inspects co-pairs only inside blocks, never the
  loop face emitted BETWEEN blocks.
- **HIGH-2: loop mis-compiled as pure choice.** A true loop net
  (a and b each precede the other) compiled to a flat ChoiceGraph with
  zero can-follow edges — the loop face erased, silently, and unrefused;
  the paper's closure-based loop court never sees it. Root ambiguity:
  relation matrix classifying true loop pairs as `:conflict`, or an
  edge-builder condition.

## Incident record

- **What**: lane files were untracked and git-clean-deleted twice
  mid-session (~11:58 and again before 12:06); the whole `lib/smalt/powl2/`
  tree including in-flight work was rotated out.
- **Protective commit**: `92e49af` (12:06:29 PT) — 16 files, 3,035
  insertions: petri_net.ex, powl2.ex, powl2/{decomposition,executor,
  hsm_signer,sb_rules}.ex, pplan/{receipt_engine,task}.ex, and 9 test
  files — "committed to stop the bleeding".
- **Residual exposure**: `reticle.ex` and `projection.ex` are STILL
  untracked on disk (`git status` `??` at 12:18 PT) and would be lost to
  another clean; `compiler.ex`/`change_feed.ex` are likewise untracked
  new files. Coordinator should checkpoint again before any clean.

## Operator-asserted vs measured (DFLSS charter interface)

The charter (`DFLSS-CHARTER.md`, standing PARTIAL_ALIVE) already carries
the distinction discipline; this wave's cells:

- **OPERATOR-ASSERTED (not repo-measured)**: the $660K–$1.2M/yr Azure
  baseline and any displacement totals derived from it. The charter marks
  these explicitly; the largest measured anchor is COST-4 ~$246/mo
  (SCENARIO mix). Unchanged by this wave — POWL2 lands no cost evidence.
- **MEASURED (this wave's contribution to CTQ-3)**: the per-gate test
  figures in the table above, each tied to a receipt or to this doc's
  own runs at a stated mtime/moment. CTQ-3's "PENDING-POWL" cell stays
  PENDING: V1 requires a **witnessed court receipt** for the POWL2 gate,
  and none exists on disk yet — the skeptic receipt is adversarial audit
  (it found HIGH-1/HIGH-2), not a closing court receipt.
- **PENDING-POWL / PENDING-RETAUTH**: no on-disk receipt authorizes
  flipping either token; both remain until closing receipts land.

## Falsifier

Re-run the table's current-run column on a fresh lane build root after
the compiler lands clean; any drift from the figures above (including
the 16/17 reticle face and the decomposition post-rewrite state) must be
re-measured, not recalled.
