# PB-4: seal_receipt dual-path bench (sorted-tuple current vs fingerprint-gated maps:fold variant)

Context: solo

**Standing: REFUTED-as-noise.** The fingerprint-gated O(n) variant is not a
measured improvement; the current sorted-tuple path stands. The O(n log n)→O(n)
WO is not gate-eligible on these numbers.

- Repo: /Users/sac/smalt (canonical checkout, no worktree)
- Lane: pb4 — lane-local harness only; nothing under `lib/`,
  `scripts/bench/`, REGISTRY.md, or `justfile.d/` modified.
- Harness: `/Users/sac/smalt/tmp/bench/pb4_merkle_dual.exs`
- Result file: `/Users/sac/smalt/tmp/bench/pb4-merkle-dual.jsonl` (16 rows, errors=0 on every row)
- Toolchain actually used by the bench: **OTP 29.1.2 / ERTS 17.1.1, Elixir
  1.20.4** (asdf 29.1.2 erl placed first on PATH; the PATH-default elixir is
  Homebrew 1.19.5/OTP-28, which mix refuses on this project). The machine
  field embedded in each jsonl row was captured inside the OTP-29 VM. For the
  registry law, `just bench-machine` output:
  `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Design under test

Subject: `Smalt.PPlan.ReceiptEngine.seal_receipt/3`
(`/Users/sac/smalt/lib/smalt/pplan/receipt_engine.ex`; current path =
`Enum.sort_by(&{epoch, seq})` + `merkle_root/1` + private `ntriples/2`).

Variant (implemented only in the lane harness): an O(n) fingerprint gate —
one pass asserting epochs non-decreasing and seq strictly increasing, which is
exactly the condition under which `Enum.sort_by` is a no-op — followed by a
raw `:maps.fold` over the seq-keyed step map for the order-independent
accumulation (max epoch) and a single ordered `:lists.foldl` building leaves
and ntriples step blocks as iolists (no sort call on the fast path).
Fingerprint miss (shuffled ingest) falls back to the current path unchanged.

## Correctness gate (byte-identity)

1. Ground truth: real `ReceiptEngine.seal_receipt/3` over a live DETS file
   (open → record_step x10 → seal). Both the harness's current-path replica
   and the variant were required byte-identical to it before any timing. PASS.
2. Per-size identity: for every n in {10, 100, 10000, 100000}, sorted and
   shuffled ingest, full receipt (merkle_root, ntriples, phi_lease_final,
   signature, step_count) byte-identical between paths. PASS at every cell —
   the variant is correct, merely not faster.

An earlier harness draft had two bugs the identity gate caught (leaf order
through `:maps.fold` visit order; missing "\n" join in ntriples) — the gate
refused them, which is the gate working.

## Numbers (p50 wall, OTP 29.1.2, Apple M3 Max)

| n | current sorted | variant fast path | current shuffled | variant shuffled (fallback = current path) |
|---|---|---|---|---|
| 10 | 0.024 ms | 0.022 ms | 0.025 ms | 0.026 ms |
| 100 | 0.314 ms | 0.449 ms | 0.312 ms | 0.456 ms |
| 10_000 | 64.7 ms | 76.5 ms | 61.7 ms | 51.9 ms |
| 100_000 | 656.1 ms | 950.0 ms | 1532.5 ms | 1308.7 ms |

Heap (`:erts_debug.size/1` of receipt = 40 words at every n — the receipt term
itself is O(1) in n; max sampled process heap):

| n | current sorted | variant sorted | shuffled (both paths) |
|---|---|---|---|
| 10_000 | 1.73M words | 1.73M words | 2.07M words |
| 100_000 | 26.6M words | 18.5M words | 5.16M words |

## Verdict

**REFUTED-as-noise-or-worse.** The sort is not the dominant cost of the seal
walk. At n=100k sorted ingest the O(n) fast path is 1.45x SLOWER wall-clock
than the current `Enum.sort_by` path (950.0 ms vs 656.1 ms). Erlang's merge
sort is cheap relative to the per-step ntriples block construction and binary
materialization that both paths pay identically. The variant's only measured
advantage is ~30% lower peak transient heap at n=100k sorted (18.5M vs 26.6M
words) — a heap win without a wall-clock win is not a gate-eligible measured
improvement.

The shuffled rows exercise the fallback and confirm it is safe and cost-free:
byte-identical output, and the 1308.7 vs 1532.5 ms spread at n=100k shuffled
is between two executions of the same current-path code — inside the noise
band (p50-vs-p95 spread at that n is >500 ms), not signal.

## Receipt (replay)

```
MIX_BUILD_ROOT/_build note: run against the prebuilt _build-otp29p/dev tree with --no-compile semantics via standalone elixir (mix run was blocked by a pre-existing compile error in lib/smalt/pipeline/smalt_fond_powl_runner.erl:182 — another lane's in-flight edit, pre-existing, not session-introduced).
export PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH"
asdf exec elixir /Users/sac/smalt/tmp/bench/pb4_merkle_dual.exs
# → ground-truth PASS line, n=10/100/10k/100k identity=OK lines, "wrote 16 rows to tmp/bench/pb4-merkle-dual.jsonl"
```

## Falsifiers (would flip the verdict)

1. A variant that removes work instead of re-ordering it — e.g. building the
   ntriples blocks as iolists without per-step binary append in BOTH paths —
   measured faster than current with byte-identical output.
2. A ledger shape where the gate holds ~always AND the sort dominates (e.g.
   epochs uniform over a huge range with tiny per-step strings); none
   measured here.
3. Re-run on an idle machine showing variant sorted-ingest p50 < current p50
   at n >= 10k outside the noise band.

## Errors / honest disclosures

- 0 errors in the emitted jsonl rows.
- Pre-existing, session-unintroduced failures observed: mix compile aborts at
  `lib/smalt/pipeline/smalt_fond_powl_runner.erl:182` (illegal guard, another
  lane's in-flight edit); `_build/dev` was reclaimed mid-session by a
  concurrent process (lane cleaned around it via `_build-otp29p`).
- The ntriples diff gate caught two real variant bugs during development
  (leaf ordering, newline join) — disclosed as evidence the identity gate is
  non-vacuous.
