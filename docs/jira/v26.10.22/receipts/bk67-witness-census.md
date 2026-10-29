# BK-67 — witness corpus census refresh (dry-run classification, post-growth to ~195 receipts)

**Standing: ALIVE** (dry-run census executed for real, exit 0; classification + 5-sample STALE audit + projected cost below. DRY-RUN only — the full gated `witness-all` was NOT run; that is the wrap lane's job.)

Context: solo · Date: 2026-10-21 · Repo: /Users/sac/smalt (branch main)
Recipe: BK-44 (`justfile.d/44-witness.just`, `scripts/witness_all.py --dry-run`)

## Run receipt

```
$ just witness-all-dry > /tmp/witness_dry.txt 2>&1; echo "EXIT=$?"
EXIT=0
[WITNESS-SUMMARY] total=198 witnessed-green=0 stale-typed=86 failed=60 (DRY-RUN)
```

Corpus: `docs/jira/v26.10.21/receipts/*.md` — 198 receipts walked (up from ~195 cited in dispatch).

## Class histogram (52 safe-rerunnable vs 86 WITNESS-STALE vs 60 WITNESS-FAIL)

| class | count | note |
|---|---|---|
| mix-test | 37 | file-scoped court tests, each with its own `MIX_BUILD_ROOT=_build-*` |
| readonly | 12 | ls/grep/head/shasum witnesses (incl. graphlaw target + OTP-29 source probes) |
| just-gate | 2 | `just docs-dod-check` (ttv8-spec-bounds, wrap1-duckdb-rescope-decision) |
| script | 1 | `python3 scripts/kd_flip.py` (bk6-kd157-h2-postrestart-witness) |
| cargo | 0 | none in this corpus window |
| WITNESS-STALE (typed) | 86 | 70 × "no command in a safe class", 16 × "no rerunnable command in receipt" |
| WITNESS-FAIL | 60 | every one is NO-STANDING (missing/malformed standing line) |

Cross-check: 52 + 86 + 60 = 198 = total. Exit was 0 because DRY-RUN only reports; a real run exits 1 on the 60 failures.

## 5-sample STALE audit (reasons lawful, not lazy)

| receipt | typed reason | verdict |
|---|---|---|
| `bk9-popcorn-live-leg.md` (ALIVE) | no command in a safe class | LAWFUL — live leg needs the loopback substrate on 9443 + a browser-WASM demo host; a file-scoped mix test cannot witness it |
| `obs4court-peer-two-node.md` (ALIVE) | no command in a safe class | LAWFUL — two-node distributed court (named nodes, `:peer`, epmd teardown, lane build root `_build-obs4`); not a single-command rerun |
| `ttv7b-quiesced-rerun.md` (BLOCKED-ON-QUIESCENCE) | no command in a safe class | LAWFUL — pre-registered gate requires 1-min load < 32 for a quiesced window; the receipt itself documents 13 min of samples ≥ 84.5. Environment-gated, expensive by design |
| `bench8-court-bench-escript.md` (PASS) | no command in a safe class | LAWFUL — bench-harness class (erlc subprocess + escript dispatch over `_bench-escript`); bench lanes are outside the safe-class allowlist by design |
| `cas412-cosmos-replace-if-match.md` (ALIVE) | no rerunnable command in receipt | LAWFUL — witness rode the real @azure/cosmos 4.10.1 SDK over the TLS twin (substrate-dependent); no command in the receipt is substrate-free |

5/5 sampled STALE dispositions have a lawful typed reason: substrate-dependent (3), environment/expensive (1), bench-class (1). Zero lazy exclusions found in the sample.

## Standing-line failures (the gate's other class)

All 60 WITNESS-FAIL entries are NO-STANDING — the receipt lacks a parseable standing line, not a rerun failure. Block-listed examples: `armstrong-idiom-census`, `bench10-skeptic`, `bk38-lane-lease-census`, `gl2-law-compiler`, `ja1-supervision-census`, `val-prd`, `wp1-lithography-whitepaper`. Secondary observation: several standing lines are malformed mid-token even when present (e.g. `amqp10-crash-only-router.md` shows `**PARTIAL_ALIVE)` with the closing `**` dropped; `ja14-release-handling.md` shows `**PARTIAL)`) — these parse as STALE, not FAIL, but are the same hygiene debt and would be repaired by the same backfill pass.

## Projected full-run cost (count × expected duration by class)

Cost driver: each mix-test entry uses its own private `MIX_BUILD_ROOT` — cold roots pay a full project compile (~2–4 min each), warm roots drop to the test itself (~20–60 s).

| class | count | est/unit (cold/warm) | subtotal |
|---|---|---|---|
| mix-test | 37 | ~3 min cold / ~45 s warm | ~110 min cold / ~28 min warm |
| just-gate | 2 | ~5 s | ~10 s |
| readonly | 12 | ~1 s | ~12 s |
| script | 1 | ~2 s | ~2 s |
| cargo | 0 | — | 0 |
| **total** | **52** | serial | **~110 min fully cold, ~30 min on warm build roots** |

Plus the fail-closed tail: the 60 NO-STANDING receipts exit-1 the run immediately per red; wrap lane should either backfill standing lines first or budget the repair loop. The 86 STALE are loud, not blocking.

## Boundary

- Full `witness-all` NOT executed (wrap-lane-owned; in-flight lanes on the tree: STORE-2/3/4, SPOF-A/B, SYNC-1/3, BK-35/62/63/65, W3C-C, JA-15b).
- `lib/smalt/powl2/law_compiler.ex` is modified in the tree and two new `src/smalt_store*.erl` files are untracked — mix-test legs would witness against a dirty tree; another reason the full run stays with the wrap lane.
- No commit made.
