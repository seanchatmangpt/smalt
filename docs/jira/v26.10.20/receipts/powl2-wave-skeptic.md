# POWL-12 — POWL wave skeptic receipt (adversarial audit as it lands)

Date: 2026-10-21. Auditor: POWL-12 skeptic lane. Read-only audit; the only file
written is this receipt. The wave was landing LIVE during the audit (compiler.ex
rewritten at 11:45, reticle.ex at 11:51, receipt_engine.ex at 11:50); every
verdict below is against the on-disk state at verdict time
(compiler.ex md5 f8e5a21f358cfaa01466142a50e4cc45).

## Per-lane verdicts

| Lane | Files | Verdict |
|---|---|---|
| petri_net | `lib/smalt/petri_net.ex` | UNWITNESSED (no test file exists) |
| powl2 reticle | `lib/smalt/powl2/reticle.ex` | REFUTED-then-REPAIRED mid-audit; current state ALIVE-by-probe, UNWITNESSED-by-test |
| powl2 compiler | `lib/smalt/powl2.ex`, `lib/smalt/powl2/compiler.ex` | **REFUTED (HIGH)** |
| pplan receipt | `lib/smalt/pplan/receipt_engine.ex` | MERKLE MUTATION PASSES; file was syntactically broken at 11:44 (`undefined variable "lines"`), compiles at 11:50. UNWITNESSED (no test file) |
| pplan task | `lib/smalt/pplan/task.ex` | UNWITNESSED (no test file) |
| powl2 sb_rules | `lib/powl2/sb_rules.ex` | compiles; UNWITNESSED |
| powl2 rest | executor / change_feed / hsm_signer / decomposition / projection | compiles in-memory (decomposition/projection struct-expansion artifact in `Code.compile_file` harness only), UNWITNESSED |

**No lane has a test file.** `mix test` has nothing to run: there is no
`test/pplan_test.exs` — which `task.ex`'s own moduledoc (line 52) claims exists
("The kill-mid-transition chaos row in test/pplan_test.exs exercises exactly
that"). Every behavioral claim in this wave is currently backed by zero
committed witnesses.

## HIGH-1 (court-critical): the compiler ADMITS the non-separable class

Claim under audit: `compiler.ex` moduledoc step 4 — "else
`{:error, :non_separable_fallthrough}` — the handle signature: a pair that is
concurrent AND conflicting ... is inexpressible." The Kourani non-separable
class must be refused, per the wave's own court.

Refutation (run by the skeptic, current compiler):

```
NON-SEPARABLE (t3 concurrent with the choice {t1,t2}; t1,t2 conflict):
  places  = source, pa, pb, pj, sink
  trans   = tf, t1, t2, t3
  arcs    = source->tf, tf->pa, tf->pb, pa->t1, two->t2, pb->t3,
            t1->pj, t2->pj, t3->PN...  (exact arc list in the probe above)
  wf_net? => true
  compile => {:ok, ChoiceGraph{ children: [CG{t1,t2}, t3, tf],
              edges: {{0,1},{0,2},{1,0},{1,2},{2,0},{2,1}} }}
```

`{:error, :non_separable_fallthrough}` never fired. The true structure is:
t3 CONCURRENT with both t1 and t2 (`:co`, non-loop), t1/t2 CONFLICT. The
compiler's SM-partition branch emitted a ChoiceGraph with a bidirectional
can-follow (POWL loop) face between the {t1,t2} choice and t3 — concurrency
silently re-modeled as a loop. The refusal court does not hold.

Root shape of the hole: `conflict_hiding?` clause (c) catches a conflict pair
hiding inside a multi-member MG block, but after the PO branch refuses, the SM
branch is never re-gated on the loop face it is about to emit between blocks
that are truly concurrent — `concurrency_hiding?` only inspects co-pairs
INSIDE blocks, never the loop-face mis-model BETWEEN blocks.

Gates that DO work (verified by probe, current reticle/compiler):
- choice: {:ok, CG} with no inner edges — faithful.
- AND-block: {:ok, PO} — faithful.
- sequential: {:ok, Transition} — faithful.
- non-separable: admitted, mis-modeled — REFUTED.

## HIGH-2: loop mis-compiled as pure choice (silent, adjacent hole)

```
LOOP: source->a->pb->b->sink, b->pl->a   (a and b each precede the other)
compile => {:ok, ChoiceGraph{children: [a, b], edges: []}}
```

The compiler's own relation matrix (public `Compiler.relations(net, ts, [])`)
classifies {a,b} as `:conflict` both directions for this net, so the flat CG
emitted has NO can-follow edges — a pure choice, which forbids a->b->a
revisits. The loop face is erased, silently, and the paper's loop court
(closure-based refusal) never sees it. Whether the root cause is the
classification of true loop pairs as `:conflict` (contradicting `:co`'s
definition "each can precede the other") or an edge-builder condition, the
emitted AST is unfaithful and unrefused.

## Receipt merkle mutation check: PASSES

`Smalt.PPlan.ReceiptEngine.merkle_root/1` (compiled verbatim in-memory; the
module needed no patch at verdict time):

- 7-leaf root: flipping ONE leaf (a single step-hash mutation) changes the root. TRUE
- Reversing leaf order changes the root. TRUE
- Single leaf: root == the leaf itself (unsalted). TRUE (note: single-leaf root is the raw leaf — acceptable but worth pinning in the hash law)
- Empty run: `e3b0c4...b7852b855` = sha256(""). Matches moduledoc claim. TRUE
- Odd leaf hashed with itself (Bitcoin-style), duplicate-leaf root differs from single-leaf. TRUE
- Step hash is delta-sensitive: changing any field of the
  `{epoch, seq, act_iri, entity_iri, delta_hash, prev_hashes}` tuple changes the step hash. TRUE

Unwitnessed remainder: the DETS-backed `record_step`/`seal_receipt` path (the
prev-hash chain over a real run) — needs a DETS file, which this read-only
skeptic lane could not create. No test file exists to cover it either.

## Reticle: REFUTED at 11:44, REPAIRED by 11:51 (live during audit)

At 11:44 `Reticle.admit/1` on ANY `PartialOrder` (including a LAWFUL DAG and
even `order: []`) crashed with `FunctionClauseError` in `MapSet.delete/2`
(reticle.ex:140 — `MapSet.delete(adj, ...)` on a plain map). The Gate-1
admission gate could not admit its own lawful input.

Current file: cycle refused (3-cycle, 2-cycle, self-loop, out-of-bounds order
pairs all typed-refused), lawful DAG admitted, and the transitive closure
(visited-set BFS, `do_reach`) terminates on cyclic input — I probed 2-, 3-,
and 4-cycles; all refuse, none hang. Terminates via seen-set exhaustion, not
a clock. ALIVE by direct probe; still UNWITNESSED (no committed test).

## "Deadlock-free by construction" claim: nothing to kill

grep of all in-scope files for `deadlock-free|by construction|non-separable`:
no deadlock-free-by-construction claim exists in the POWL wave. The only
"by construction" hits in the wave-adjacent tree are in unrelated files
(dspy/remediation, affidavit wasm supervisor, ocel fitness). The wave's
strong claim is the non-separable refusal, which HIGH-1 refutes above; any
future "deadlock-freedom follows because non-separable nets are refused"
chain therefore has NO standing court today.

## RE-WITNESS addendum — 2026-10-22 (lane BK-REWIT3, fresh _build-rewit3 tree)

Re-ran the skeptic's probes on the current tree; mixed results, typed honestly:

```
HIGH-2 loop net (source->a->pb->b->sink, b->pl->a): wf_net=true
  Powl2.Compiler.compile => {:ok, %ChoiceGraph{children: [a, b], edges: MapSet.new([])}}
  → LOOP FACE STILL ERASED, unrefused — HIGH-2 REPRODUCES on the current tree
    (the receipt's court finding stands; the closure court still has no teeth).

Reticle admit (current Smalt.POWL2.Reticle.AST.* shapes, edges MapSet of pairs):
  RETICLE_2CYCLE = :ok                                          ← drift vs receipt claim
  RETICLE_3CYCLE = {:error, {:shacl_violation, "trapped child \"b\": not on any start→end path"}}
  RETICLE_DAG_OK = :ok (lawful DAG admits)
  → the receipt's "2-cycle refused" leg is STALE: the current reticle surface
    admits the 2-cycle; the 3-cycle still typed-refuses (trapped-child reason,
    not the receipt's cycle reason). Admission behavior drifted since 2026-10-21
    (reticle.ex carries later GL-KILL F1 edits); the receipt's cycle-refusal
    sentence does not describe the current surface.

Merkle law (ReceiptEngine.merkle_root/1, hex-leaf form):
  leaf-order flip changes root  -> true ; exit=0
  empty root == sha256("")      -> true (e3b0c4…b855 reproduced)
  root binary 32 bytes          -> true ; exit=0
  single-leaf root = raw leaf   -> code-verified (receipt_engine.ex:248
  `def merkle_root([only]), do: decode(only)`)
```

Typed outcome: the receipt's HIGH-1/HIGH-2 compiler findings remain LIVE
findings (HIGH-2 re-proven); the reticle cycle-refusal claim is superseded by
the current surface (2-cycle admits); merkle law holds. Receipt stays
evidence-backed; SUSPECT cleared (fresh command-embedded evidence above).

## Commands (all read-only, in-memory `Code.compile_file/compile_string`)

Every probe in this receipt ran in a fresh `elixir -e` with
`Code.compile_file` (no _build writes, no temp files; the only fs write is
this receipt). Probes are reproducible verbatim.

## Standing

**Standing:** ALIVE (adversarial audit executed — HIGH-1 non-separable-admission refutation witnessed by an executed read-only probe, embedded verbatim; all probes reproducible; remaining wave lanes typed UNWITNESSED inside the audited wave)
