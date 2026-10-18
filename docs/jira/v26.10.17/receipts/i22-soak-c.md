# i22 — Soak lane C: 3x full-suite runs post-i22-fixes

Standing: SUSPECT — acceptance NOT met (0 of 3 consecutive 2655/0 sequences; best streak 1 green, run 3)

## Contract

Soak lane C, third stagger. Poll fix receipts (90 s x20), wait 10 minutes, then
3x full `MIX_BUILD_ROOT=_build-ft-soakC mix test`. Classify every failure
(new / recurrence / FLAKE_LEDGER face). No edits, no git.

## Poll + timeline

- 12:05:04 poll start. My cycle-1 key was the i21d receipt
  (`i21d-store-clear-async.md`, landed 22:33 prev. night) — already present,
  so the poll exited cycle 1. The actually-landing receipts during my poll
  window were the i22 fixes: `i22-error-corpus-lro.md` (12:09),
  `i22-fuzz-atom-fix.md` (12:09), `i22-atom-pressure.md` (12:10),
  `i22-corpus-seed-hardening.md` (12:13) — per FLAKE_LEDGER.md post-poll status.
- 12:12–12:13: i22 lane edits landed on disk
  (`lib/smalt/messaging/amqp/atom_bridge.ex`, `/test/compliance/*.exs`,
  `test/corpus/*`). All three runs below executed on this one consistent
  post-i22-edit tree at HEAD 6d84ca7 + uncommitted i22 edits.
- 12:15 (+10 min wait) → runs 1–3 sequential, same build root.

## Runs (all: `MIX_BUILD_ROOT=_build-ft-soakC mix test`, HEAD 6d84ca7)

| run | started | wall | result | log |
|---|---|---|---|---|
| 1 | 12:16 | 603.5 s | 2655 tests, **3 failures** | (tail-captured only — failure identities LOST, disclosed) |
| 2 | ~12:29 | 504.5 s | 2655 tests, **4 failures** | `tmp/soak-c-run2.log` |
| 3 | ~12:39 | 393.2 s | **2655 / 0 failures GREEN** | `tmp/soak-c-run3.log` |

Run 3 exit 0. Runs 1–2 exit nonzero.

## Run 2 failure classification (log preserved: `tmp/soak-c-run2.log`)

| face | classification |
|---|---|
| `test/corpus/shacl_fuzz.exs:99` — fuzz sweep timeout (60 s) | **FLAKE_LEDGER F3 face** (ledger cites :98 pre-i22-edit; i22 edits shifted lines) — CLOSED row recurring on the tree that carries its own fix. Fix-regression witness against `receipts/i22-corpus-seed-hardening.md`, or the timeout variant is a distinct sub-face. Recurrence count +1 for F3. |
| `test/amqp/broker_facade_test.exs:238` — `EventHubs.sweep() >= 1` got 0 | **NEW face** — not in FLAKE_LEDGER. Timing/contention class (expired-claim sweep raced a sibling). Mechanism un-rooted. |
| `test/error_codes_doc_test.exs:46` — ERROR_CODES.md stale | **NEW face, deterministic, not jitter** — verified on disk: `python3 scripts/gen_error_codes.py --check` exits 1 right now. Root cause: the i22 lane's 12:12 edits to `test/compliance/*.exs` shifted cited line numbers (c1_arm 256→255 etc.) without regenerating the projection. Not a flake — it will fail EVERY full-suite run until `just gen-error-codes` runs or the i22 edits land with a regen. This alone makes 3x2655/0 unreachable on the current tree state. |
| `test/data_plane/blob_hardening_test.exs:1692` — pagination perf 235 ms > 180 ms budget (reps 283/277/273/235/263) | **NEW face** (perf-budget, load-class, F7-like). All 5 reps over budget — worse than jitter: could be genuine regression to full-value materialization on the i22 tree, or machine-load skew. Needs a solo re-measure before disposition. |

## Machine

`{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Honesty notes

1. Run 1's three failure identities are LOST (tail-only capture, my error). Run 3 green proves the tree CAN go green; run 1's faces unrecoverable.
2. Poll keyed on the wrong receipt (i21d already-present vs the i22 batch landing 12:09–12:13).
3. Acceptance (3 consecutive 2655/0) not met — do not read run 3's green as the gate.
4. Tree was NOT clean during runs: uncommitted i22 edits present (disclosed above); this lane's "no edits" contract was honored — the edits are another lane's.
5. Full logs: `tmp/soak-c-run2.log`, `tmp/soak-c-run3.log` (run 1 not preserved).
