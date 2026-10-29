# GL-12 Full-Stack Seal Court — Receipt

- **Lane**: GL-12 (writer, OTP-29)
- **Subject**: `test/integration/graphlaw_fullstack_court.exs` (new, 1 file owned by this lane)
**Standing**: ALIVE — court 2/2 green, reproduced 3 consecutive runs (seeds 500463, +2 more)
- **Context**: full
- **Date**: 2026-10-21

## Court file

`/Users/sac/smalt/test/integration/graphlaw_fullstack_court.exs` — one law-governed
settlement run, end to end:

- GL-2: `Smalt.POWL2.LawCompiler.compile_shape/2` compiles the real SHACL TTL
  (`HighValueOrderShape`, `sh:maxInclusive 10000` on `totalAmount`) into the guard
  predicate. Witness: the refusal rule id is the compiled rule id
  `ex:HighValueOrderShape/maxInclusive/totalAmount`.
- GL-1: guard rides the `Smalt.POWL2.Executor` law-guard seam
  (`law_guard: {shape_id, fun}` overlay on the validate transition; FOND repair via
  the node-level `:repair` seam). Refusal fired on step 3 of 7 with the op never
  run (fail-closed): the only CAS mutations are intake-create (201) and the
  post-repair commit (200, If-Match on the intake etag — etag chain e1 != e0,
  live etag == commit etag).
- FOND: the repair is the executor's `:repair` node — the refusal step AND the
  repair step both appear in the run's step list, in order
  (intake, persist, **validate ANDON**, repair, commit, settle, done).
- GL-12: every step (lawful AND refused) recorded into `Smalt.PPlan.ReceiptEngine`;
  the ANDON rides the ledger as a `Smalt.Powl2.Andon.format_andon/4` receipt
  (GL-3 shape, with `json_ld`). Seal assertions: ANDON `delta_hash` is one of the
  Merkle leaves; root recomputed over ALL leaves == sealed `merkle_root` (32 bytes);
  `phi_lease_final == step_count == ledger length == 7`; epoch sequence 1..7 in
  order; HSM signature verifies against the refusal-inclusive root.
- GL-8: the SAME refusal serves the wire via `Smalt.Powl2.AndonWire`:
  HTTP `http_envelope/2` → 422 + `{"error": {"code": "GraphlawRefusal", ...}}` with
  identical rule_id / diagnostic / context_digest as the ledger; AMQP
  `amqp_properties/2` → byte-identical body, `andon.rule_id` /
  `andon.context_digest` application properties, typed `andon_ts_long` == receipt ts.
- Control test: fully lawful $5k run — zero ANDON steps, clean path
  intake→persist→validate→commit→settle→done, seal phi_lease == step count.

## Real output (final run)

```
Running ExUnit with seed: 500463, max_cases: 32
..
Finished in 0.2 seconds (0.00s async, 0.2s sync)
Result: 2 passed
```

3 consecutive runs: `Result: 2 passed` x3.

Adjacent owning-surface courts after this lane's edits (regression boundary):

```
mix test test/integration/graphlaw_powl_business_net.exs test/internal/powl2_law_guard_court.exs test/integration/powl2_gates_court.exs
[POWL-10c] whole-orchestration latency: 18 ms (fence 500 ms)
Result: 24 passed
```

## Commands

```
MIX_BUILD_ROOT=_build-gl12 asdf exec mix test test/integration/graphlaw_fullstack_court.exs
```

(exit 0 on all runs; toolchain from repo `.tool-versions`: OTP 29.1.2 / Elixir
1.20.4-otp-29; MIX_BUILD_ROOT=_build-gl12)

## Findings typed on record (pre-existing, not introduced by this lane)

1. **Executor start-node semantics** (witnessed, not fixed — GL-1 lane's surface):
   the executor's ChoiceGraph walk evaluates TARGETS only; the `start` node is
   never stepped. The court carries an explicit unevaluated `:entry` delimiter
   (same pattern GL-4's court relies on implicitly). If the GL-1 lane intends
   start-node evaluation, this court's delimiter comment marks the seam.
2. **GL-4 court defect (pre-existing)**: `graphlaw_powl_business_net.exs` calls
   `:dets.open_file(..., autoheal: false)` — `autoheal` is rejected with
   ArgumentError on OTP 29 stdlib (probed standalone). That court cannot pass as
   written; this lane's court uses plain `file:` open. Owner: GL-4 lane.
3. **`sh:path` ctx-key law**: the LawCompiler resolves `sh:path` prefixed names
   verbatim (`ex:totalAmount` looks up key `"ex:totalAmount"`); context keys must
   be bare local names or match the prefix exactly. Pinned in the court TTL
   (`sh:path totalAmount`).

## Compile-freeze disclosures (same-checkout fan-out SLA)

This lane applied minimal unblock fixes to OTHER lanes' in-flight files after the
~10-minute SLA elapsed (both lanes' receipts must name these):

- `lib/smalt/wasm/worker.ex` — self-resolved by its owner mid-window (no edit by
  this lane).
- `lib/smalt/data_plane/{file_share,cosmos,blob_storage,cosmos_query_metrics}.ex`,
  `lib/smalt/egress_router.ex`, `lib/smalt/messaging/amqp10/frame_decoder.ex` —
  the IMPL-27 warnings sweep had replaced the `defguardp int_in/3` body with
  `:erlang.is_integer(x, lo, hi)` (not legal inside a guard under Elixir 1.20;
  6 files, full-tree compile abort). This lane expanded each to the semantically
  identical `is_integer(x) and x >= lo and x <= hi`. Owner lane (IMPL-27 / IMPL-2
  adoption) must re-adopt or re-derive; the fix is disclosed here because this
  receipt is the only witness.

## Artifacts

- Court: `/Users/sac/smalt/test/integration/graphlaw_fullstack_court.exs`
- Receipt: `/Users/sac/smalt/docs/jira/v26.10.21/receipts/gl12-fullstack-seal-court.md`
- Lane build root left for coordinator: `_build-gl12` (deleted at integration per
  cleanup law).

## Falsifier status

Spec falsifier "Refusal omitted from sealed token" is REFUTED for this court: the
recomputed Merkle root over leaves that include the ANDON delta hash equals the
sealed root — a seal that dropped the refusal would fail the court.
