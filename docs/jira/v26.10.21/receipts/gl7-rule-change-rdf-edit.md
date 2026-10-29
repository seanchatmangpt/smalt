# GL-7: Rule change = RDF edit, not refactor

**Standing: ALIVE** (court green on the exact subject; 4/4 tests, 0 failures, 0 errors)
Context: solo

**Date:** 2026-10-21 · **Lane:** GL-7 (writer, OTP-29) · **Build root:** `_build-gl7`
**Toolchain:** Elixir 1.20.4-otp-29 / Erlang/OTP 29.1.2 (`~/.asdf/installs/{erlang/29.1.2,elixir/1.20.4-otp-29}`)

## Subject

- `test/integration/graphlaw_rule_change.exs` — new court file (untracked; coordinator commits per lane)
- `lib/smalt/powl2/law_compiler.ex` — one structural addition: `read_blocks/1` +
  `sh:property [ ... ] , [ ... ]` comma-separated property blocks (the doubled-bracket
  multi-block form the `Smalt.GraphLaw.Validator.ShapeFile` substrate already accepts).
  Committed in coordinator tick 322ed1e. Without it, a two-signature law cannot be
  expressed as a single TTL shape.

## The property under proof

The SAME settlement net (one AST: begin -> intake -> validate -> commit -> settle -> done)
runs three times under three compiled laws — each law is a TTL string handed to
`Smalt.POWL2.LawCompiler.compile_shape/2`, never a code edit:

1. `sh:maxInclusive 10000` on `totalAmount` — the $15k order (no signature) ANDONs.
2. `sh:maxInclusive 20_000` — the SAME $15k order admits (commit really CAS-creates the
   ChangeFeed document, 201 + etag verified against `ChangeFeed.etag/3`).
3. two required signatures (`sh:minCount 1` on `complianceSignature` + `financeSignature`)
   — ANDON returns, fail-closed on the first missing signature.

## Courts

- **run 1** — `{:error, {:powl2_andon, :validate, "OrderShape/maxInclusive/totalAmount", diag}}`;
  walk stops at validate (`[:intake, :validate]`), commit never fires, ChangeFeed holds no
  document, `{:powl2_andon, :validate, ...}` row persisted in DETS, failed receipt
  `status: {:error, andon}`; refusal re-sealed via `Smalt.Plan.ReceiptEngine` (step_count,
  phi_lease_final == step count, 32-byte merkle root, HSM-signed); the court additionally
  mints the agent-consumable ANDON receipt via `Smalt.Powl2.Andon.format_andon/4`
  (context digest commits to the exact refused order, repair hint present).
- **run 2** — full path `[:intake, :validate, :commit, :settle, :done]`, commit CAS 201,
  etag identity.
- **run 3** — ANDON returns; fail-closed first-violation
  `OrderShape/minCount/complianceSignature`.
- **property court** — topology (ids, transition ids, start, end, edges, guards) identical
  across all three laws (`Enum.uniq(topologies) |> length == 1`), while the guards provably
  diverge on the same $15k order: v1 refuses / v2 admits / v3 refuses. Rules live in the
  shapes, not the net.

## Verification (actual output)

```
$ MIX_BUILD_ROOT=_build-gl7 mix test test/integration/graphlaw_rule_change.exs
....
Finished in 0.1 seconds (0.00s async, 0.1s sync)
Result: 4 passed
```

Repeated clean (two consecutive green runs; the last one after all shared-lib drift
settled). Only output notice is the repo-wide `.exs` test-load-filter warning that every
`test/integration/*.exs` court already emits — no code warnings from the new file.

## Execution receipts (Chicago: real collaborators, no mocks)

- `Smalt.POWL2.Executor.execute_admitted/6` over the reticle-admitted net
  (`Reticle.admit/1 == :ok` per run).
- Law guards ride the executor's native guard seam: `{:graphlaw_guard, "OrderShape", fun}`
  op on the validate transition, with a fixed net-side adapter (`guard.(ctx.order)`)
  identical across all three laws — only the compiled fun swapped.
- `Smalt.POWL2.ChangeFeed` CAS commit (real 201/etag), DETS receipt/andon persistence
  (OTP-29 `dets:open_file(file: ..., repair: true)` — the `path:` option is badarg on
  OTP-29), `Smalt.PPlan.ReceiptEngine` + `Smalt.Powl2.HsmSigner` seal.
- Laws are compiled from three TTL strings; zero code edits between runs 1/2/3.

## Net-side notes (executor semantics, disclosed)

- The executor enters the walk by picking an edge FROM `start` (start is never evaluated),
  so the net begins with a tau `:begin` entry node whose edge fires `intake`.
- Pure guard nodes leave `last_outcome` untouched; the court's net therefore uses
  unguarded fallback edges (`guards: %{}`) — enforcement is at the validate node's law
  guard, not by edge guards, in every law.
- The guard receives the walk ctx (not the order map); the fixed adapter narrows it.

## Falsifier

Change a law without recompiling the guard, or change the net's edges/ids across runs —
the property court asserts `length(Enum.uniq(topologies)) == 1` and would fail loudly.

## Non-vacuity

The ANDON genuinely fires and genuinely clears: run 1 vs run 2 differ only in the TTL
threshold literal (`10000` -> `20000`) and the verdict flips refusal -> admission over a
byte-identical order map and a byte-identical net.
