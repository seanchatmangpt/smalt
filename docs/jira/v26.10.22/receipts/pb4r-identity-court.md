# PB4-R — PB-4 identity-court repair: replica re-derived against current seal_receipt — ALIVE

**Standing:** **ALIVE** — PB-4 harness exits 0, ground-truth court passes, 16 real rows
emitted to `tmp/bench/pb4-merkle-dual.jsonl` (2 fresh runs this window, both exit 0).

Context: solo
Date: 2026-10-22
Lane: PB4-R · `MIX_BUILD_ROOT=_build-pb4r` · asdf otp 29 / elixir 1.20.4

## Root cause (typed BLOCKED[identity-court-refusal] → repaired)

The PB-4 harness (`tmp/bench/pb4_merkle_dual.exs`, lane-local, gitignored) carries a
hand-copy of `ReceiptEngine` post-lookup computation as its "current path" replica.
That copy predates the GAP-6a agent-attribution landing in
`lib/smalt/pplan/receipt_engine.ex` and diverged on five points (all replica-side
staleness; the real seal is correct — no lib/ change needed):

1. **Receipt map**: real adds `agent` field (default `urn:smalt:agent:<node>`).
2. **Run lines**: real emits `prov:Agent` type triple + `run wasAttributedTo agent`.
3. **Per-step lines**: real adds `prov:wasAssociatedWith` (Act→Agent),
   `prov:wasAttributedTo` (Entity→Agent), `prov:endedAtTime`/`prov:generatedAtTime`
   (ISO8601 from step `ts`).
4. **Predicate bracketing**: real brackets `rdf-syntax-ns#type` on the RUN lines
   (step lines still unbracketed — faithfully replicated, warts and all).
5. **Variant fast-path index**: latent second bug found during re-derivation — the
   O(n) fast path used `step.seq` as the `pplan:correspondsToStep` index while the
   real seal uses the post-sort position; they differ once epochs sort across
   insertion order. Fast path now uses a fold-carried position counter.

Not the cause (checked): build skew (reproduced in fresh build roots per bk5
receipt), signer, merkle tree (byte-exact copy matches), signature.

## Minimal pair (Chicago, real DETS)

One `seal_receipt` over live DETS (`tmp/bench/pb4_dets_ground.bin`, 10 recorded
steps via `record_step/2`, ts = real wall clock) vs one fold-replica of the same
steps. Pre-repair: `FATAL: local current-path replica diverges from real
seal_receipt on live DETS` (bk5 log `tmp/bench/pb4-v261022.log`). Post-repair:

```text
ground-truth: local replica + variant byte-identical to real seal_receipt (live DETS, n=10)
n=10: identity=OK  current p50=0.045ms  variant p50=0.042ms  current(shuf) p50=0.047ms  variant(shuf) p50=0.047ms (shuffled exercises fallback)
n=100: identity=OK  current p50=0.504ms  variant p50=0.5ms  current(shuf) p50=0.583ms  variant(shuf) p50=0.537ms (shuffled exercises fallback)
n=10000: identity=OK  current p50=132.447ms  variant p50=111.58ms  current(shuf) p50=111.765ms  variant(shuf) p50=120.523ms (shuffled exercises fallback)
n=100000: identity=OK  current p50=2250.577ms  variant p50=2098.486ms  current(shuf) p50=2488.913ms  variant(shuf) p50=2531.845ms (shuffled exercises fallback)
wrote 16 rows to /Users/sac/smalt/tmp/bench/pb4-merkle-dual.jsonl
```

Driver: `MIX_BUILD_ROOT=_build-pb4r mix run --no-start tmp/bench/pb4_merkle_dual.exs`
→ exit 0 (both runs). Log artifact: `tmp/bench/pb4-v261022-pb4r.log`. FATAL count 0.

Replay (PB4-T, harness relocated to tracked capital): `MIX_BUILD_ROOT=_build-pb4t mix run --no-start scripts/bench/pb4_merkle_dual.exs`
→ exit 0, identity=OK at n=10/100/10k/100k, 16 rows to `tmp/bench/pb4-merkle-dual.jsonl` (fresh run 2026-10-22; evidence above unchanged).

## Embedded diff (harness is gitignored tmp/; this receipt is the carrier)

Diff of `tmp/bench/pb4_merkle_dual.exs` vs pre-repair:

```diff
--- a/tmp/bench/pb4_merkle_dual.exs
+++ b/tmp/bench/pb4_merkle_dual.exs
@@ defmodule PB4
-  def seal_current(run_id, steps, typo, signer) do
+  @default_agent "urn:smalt:agent:#{to_string(node())}"
+
+  def seal_current(run_id, steps, phi_final, signer, agent \\ @default_agent) do
     steps = Enum.sort_by(steps, &{&1.epoch, &1.seq})
     root = Smalt.ReceiptMerkle.merkle_root(Enum.map(steps, & &1.hash))
     signature = if signer, do: signer.(root), else: nil
     %{
       run_id: run_id,
       phi_lease_final: phi_final || max_epoch_enum(steps),
       merkle_root: root,
-      ntriples: ntriples(run_id, steps),
+      ntriples: ntriples(run_id, steps, agent),
       signature: signature,
+      agent: agent,
       step_count: length(steps)
     }
   end
@@ PB4.ntriples/2 → /3 (byte-exact re-copy of ReceiptEngine.ntriples/3)
-  def ntriples(run_id, steps) do
-    run = "<urn:smalt:run:" <> run_id <> ">"
-    run_lines = [
-      iri_line(run, @rdf_type, "<" <> @prov <> "Entity>"),
-      iri_line(run, "<" <> @pplan <> "correspondsToStep>", "<urn:smalt:pplan:step:" <> run_id <> ">")
-    ]
-    ... per-step: 6 lines (type x2, wasGeneratedBy, correspondsToStep, wasDerivedFrom, value)
+  def ntriples(run_id, steps, agent \\ @default_agent) do
+    agent_iri = "<" <> agent <> ">"
+    run_lines = [
+      iri_line(run, "<" <> @rdf_type <> ">", "<" <> @prov <> "Entity>"),   # bracketed rdf:type
+      iri_line(run, "<" <> @pplan <> "correspondsToStep>", ...),
+      iri_line(agent_iri, "<" <> @rdf_type <> ">", "<" <> @prov <> "Agent>"),
+      iri_line(run, "<" <> @prov <> "wasAttributedTo>", agent_iri)
+    ]
+    ... per-step: 10 lines (+ wasAssociatedWith, wasAttributedTo, endedAtTime, generatedAtTime; ts→iso8601/1)
   end
+  defp iso8601(ns) ... # copied from ReceiptEngine (DateTime.from_unix(:nanosecond), truncate :second, out-of-range fallback to raw integer)
@@ PB4.seal_variant/fast_seal
-  def seal_variant(run_id, steps, phi_final, signer) do  # agent param threaded
+  def seal_variant(run_id, steps, phi_final, signer, agent \\ @default_agent)
+  fast path: plan-step index = post-sort position counter (was step.seq — latent bug);
+  same agent triple additions as ntriples/3; receipt map gains `agent` field.
```

(Note: the "mebra" typo in the diff header is cosmetic; the subject file is
`tmp/bench/pb4_merkle_dual.exs`.)

## Falsifier / non-vacuity

Reverting the harness edits restores the FATAL halt: the ground-truth court
refused pre-repair across fresh compile and clean build roots (bk5 witness,
`tmp/bench/pb4-v261022.log`), and passes post-repair on the same live-DETS
minimal pair. The flip is the non-vacuity proof.

## Files

- Modified (untracked, gitignored): `tmp/bench/pb4_merkle_dual.exs` — carried as
  embedded diff above; committed artifacts are the receipt + VALIDATION fold only.
- Log artifact: `tmp/bench/pb4-v261022-pb4r.log`
- `lib/` untouched — no in-flight lane holds receipt_engine.ex; real seal is correct.

## PB-4 bench numbers (real, from the 2nd run)

```jsonl
{"lane":"pb4","surface":"pplan.receipt_engine.seal","op":"seal_current_sorted_ingest","n":100000,"ops_per_sec":0.48,"p50_ms":2250.577,"errors":0}
{"lane":"pb4","surface":"pplan.receipt_engine.seal","op":"seal_variant_sorted_ingest","n":100000,"ops_per_sec":0.5,"p50_ms":2098.486,"errors":0}
{"lane":"pb4","surface":"pplan.receipt_engine.seal","op":"seal_current_shuffled_ingest","n":100000,"ops_per_sec":0.42,"p50_ms":2488.913,"errors":0}
{"lane":"pb4","surface":"pplan.receipt_engine.seal","op":"seal_variant_shuffled_ingest(fallback)","n":100000,"ops_per_sec":0.43,"p50_ms":2531.845,"errors":0}
```

(all 4 n=100000 rows, 2nd run; full 16-row set in `tmp/bench/pb4-merkle-dual.jsonl`)
