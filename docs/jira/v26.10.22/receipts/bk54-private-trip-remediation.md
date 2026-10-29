# BK-54 — COURT-PRIVATE-TRIP remediation: honest RED → GREEN

**Standing:** **ALIVE** (gate exit 0 on the real tree; touched surfaces witnessed)
Context: solo
Date: 2026-10-21 · Closes the falsifier in
`docs/jira/v26.10.22/receipts/bk50-private-trip.md` (Class A/B/C triage). No commit (per WO).

## Gate transcript

```
$ just private-trip
PRIVATE-TRIP PASS: clean (879 source files scanned)
exit: 0
```

Hit count: **41 hits / 27 files → 0 hits / 0 files**. Self-test still non-vacuous
(`--self-test` REFUSE witnessed in bk50; gate script untouched this lane).

## Class A — repo-root constants → derived (16 sites)

- `scripts/bench/impl17_amqp_reductions.exs:13`, `scripts/bench/pb2_reductions_step.exs:42`,
  `test/integration/fixtures/sqld2/generate_dump.exs:128` → `Path.expand("tmp/...", File.cwd!())`
- `scripts/bench/ja9_scaling.exs:12` → `repo_root = File.cwd!()` (+ comment)
- `scripts/bench/pb6_dual_boundary.exs` (5 attrs) → `@repo_root File.cwd!()` +
  `Path.expand(..., @repo_root)`
- `scripts/bench/pb6_wire_leg.mjs:18-19`, `scripts/bench/scvd_tier2.mjs:12`,
  `scripts/bench/scvd_tier3.mjs:17` → `new URL("../../...", import.meta.url).pathname`
- `scripts/bench/sqld8_ingest_baseline.sh:7`, `scripts/bench/pb5_crosslang.sh:5` →
  `REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"`
- `scripts/demo_migration_rehearsal.sh:21` → script-dir-derived default
- `test/courts/court_wire.erl:35` → `?CA_FILE` macro expands to a runtime
  `os:getenv("SMALT_CA_FILE")` lookup; runner `scripts/courts/court_wire.sh` now
  exports `SMALT_CA_FILE="$ROOT/.smalt/tls/ca-cert.pem"` (repo-relative fallback).
  erlc clean (2 pre-existing warnings, unchanged).
- `test/integration/gld5fix_roundtrip_court.exs:24,203`,
  `test/integration/sqld2_sql_ingest_court.exs:9,255` → `Path.expand(..., File.cwd!())`
- `scripts/bench/sqld8_ingest_baseline.exs:98` → `Path.expand(..., File.cwd!())`

## Class B — comment/quoted-command paths → repo-relative rephrase (16 sites)

`live_acr.ex:5`, `ctq2_txn.mjs:19`, `impl17:6`, `pb2:26`, `witness_all.py:20`,
`ja12:2,14`, `ja13:12`, `sj1:2` rephrased to `repo root` / `<repo-root>`;
`amqp10_ledger_owner_court_test.exs:22`, `amqp_kd131_133_triage_test.exs:29`,
`ja7:27`, `kd155:31`, `amqp_listener_cap_test.exs:12` switched to
`Code.require_file(Path.expand("../internal/poll_helper.exs", __DIR__))`.

## Class C — external graphlaw path → env-derived with committed default (7 sites)

`scripts/witness_all.py:36` → `GRAPHLAW = os.environ.get("GRAPHLAW_ROOT", <repo>/../graphlaw)`
(repo-root-relative default, not a home literal).
`test/integration/wasm_real_runner_court.exs:22,24,25,37` →
`Path.expand(System.get_env("GRAPHLAW_ROOT", "../graphlaw") <> "/...")`;
default assumes the sibling canonical checkout `/Users/sac/graphlaw` (documented in file).
`test/integration/ath3_law_court.exs:37-38` (committed by another lane mid-remediation,
same class) → same `GRAPHLAW_ROOT` pattern (`@graphlaw_root` attribute). Minimal
disjoint 2-line fix on a lane-dirty file — disclosed per the compile-freeze disclosure law.

## Verification (real output)

| Surface | Command | Result |
|---|---|---|
| Gate | `just private-trip` | exit 0, "clean (879 source files scanned)" |
| 4 touched test files | `MIX_BUILD_ROOT=_build-bk54 mix test test/internal/amqp_listener_cap_test.exs test/integration/{kd155_delete_framing_test,amqp_kd131_133_triage_test,amqp10_ledger_owner_court_test}.exs` | **17 passed**, exit 0 |
| Wasm real-runner court | `MIX_BUILD_ROOT=_build-bk54 mix test test/integration/wasm_real_runner_court.exs` | **7 passed**, exit 0; log shows `[GWS-18] real-runner court active: /Users/sac/graphlaw/target/release/graphlaw-run` — committed `../graphlaw` default resolves to the sibling checkout with no env set |
| ath3 court | `mix run --no-start -e 'Code.compile_file("test/integration/ath3_law_court.exs")'` (_build-bk54) | exit 0 (court ran to completion) |
| witness_all | `python3 scripts/witness_all.py --dry-run` | exit 0 |
| Erl court compile | `erlc test/courts/court_wire.erl` | OK (2 pre-existing warnings, unchanged) |
| Syntax | `elixir -e Code.string_to_quoted!` / `node --check` / `bash -n` / `py_compile` | all 28 touched files parse clean |

## Carry / notes

- `test/integration/amqp10_ledger_owner_court_test.exs` was lane-dirty (another
  lane editing the module body); my edit is the disjoint line-22 require path — disclosed.
- Gate wiring into `just court` (PRD) is now unblocked; left to the coordinator
  (not done here — court wiring changes every lane's gate surface).
- `mix test` for this lane rode `_build-bk54`; lane build root `_build-bk54`
  is a lease — delete at integration per the cleanup law.
