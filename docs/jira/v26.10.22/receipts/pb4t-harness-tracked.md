# PB4-T — PB-4 harness relocated to tracked capital — ALIVE

Closes the harness-durability debt PB4-R disclosed: the PB-4 ground-truth
harness lived at `tmp/bench/pb4_merkle_dual.exs` — gitignored lane-local
scratch (the W2 class EXP1-B fixed for idb-shim: court truth in scratch is
dead on fresh clone).

## Change

- Harness moved to `scripts/bench/pb4_merkle_dual.exs` (tracked).
- Path assumptions fixed: hardcoded `/Users/sac/smalt/` prefix replaced with
  `File.cwd!()`-relative resolution (`PB4_BUILD_ROOT` env override retained,
  default now `_build/dev`). Output paths stay `tmp/` (outputs are scratch,
  harness is capital). Run-line comment updated to the new tracked command.
- Receipt pointer updates: `pb4r-identity-court.md` (replay-command line
  added; original evidence untouched) and `bk5-powlbench.md` PB-4 section
  (harness pointer line only).

## Replay (Chicago: the replay IS the verification)

Command: `MIX_BUILD_ROOT=_build-pb4t mix run --no-start scripts/bench/pb4_merkle_dual.exs`
Ran twice this lane (before and after the path fix), both exit 0.
Post-fix run output (fresh 2026-10-22, Context: solo):

```text
ground-truth: local replica + variant byte-identical to real seal_receipt (live DETS, n=10)
n=10: identity=OK  current p50=0.048ms  variant p50=0.044ms  current(shuf) p50=0.06ms  variant(shuf) p50=0.051ms (shuffled exercises fallback)
n=100: identity=OK  current p50=0.563ms  variant p50=0.532ms  current(shuf) p50=0.612ms  variant(shuf) p50=0.508ms (shuffled exercises fallback)
n=10000: identity=OK  current p50=131.557ms  variant p50=127.275ms  current(shuf) p50=97.143ms  variant(shuf) p50=107.318ms (shuffled exercises fallback)
n=100000: identity=OK  current p50=2399.45ms  variant p50=2209.113ms  current(shuf) p50=2473.327ms  variant(shuf) p50=2655.164ms (shuffled exercises fallback)
wrote 16 rows to /Users/sac/smalt/tmp/bench/pb4-merkle-dual.jsonl
```

**Standing:** ALIVE — ground-truth court green over live DETS, identity=OK at
n=10/100/10k/100k, 16 real rows emitted from the tracked path.
