# BK-50 — COURT-PRIVATE-TRIP: private-token tripwire gate

**Standing:** PARTIAL_ALIVE (gate + non-vacuity self-test ALIVE; real-tree scan honest RED — 41 hits listed for triage, no mass-delete per WO)
Context: solo
Date: 2026-10-21 · PRD-26.10.22-SOVEREIGN-CORE §4 COURT-PRIVATE-TRIP / NFR-SEC-004 · Scrub precedent 404efe2

## Design

`scripts/private_trip.py` — fail-closed tree scan over `git ls-files` limited to
source dirs (`lib/`, `test/`, `workspace/`, `scripts/`, `justfile.d/`,
`popcorn_demo/lib/`; docs/ excluded since receipts quote sandbox commands in
prose). Patterns:

1. Structural: `/Users/[a-z]+/` absolute-home-path regex (self-safe: the
   literal pattern text `/Users/[a-z]+/` does not match its own regex — `[`
   is outside `[a-z]`).
2. Env-supplied: `PRIVATE_TRIP_TOKENS` (comma-separated). Committed config
   carries NO private name — the scrub precedent (404efe2) keeps names out of
   HEAD; names ride env per invocation.

Robustness details: gate script excludes itself (`SELF` basename); binary
files skipped by NUL-byte sniff (`.wasm` text-mangle false positives);
worktree-deleted-but-indexed files skipped (`FileNotFoundError`), other
read errors REFUSE.

Exits: 0 clean · 1 hits (file:line list) or scan-infrastructure failure ·
2 VACUOUS GATE (self-test fails to refuse planted tokens).

## Wiring

- `justfile.d/48-private-trip.just` — `just private-trip` / `just private-trip-self-test`.
- Import line added to root `justfile` (was clean of other-lane edits):
  `import 'justfile.d/48-private-trip.just'`.
- NOT yet wired into `just court` (PRD names that wiring; deferred until the
  honest RED is triaged to green — wiring now would red every court).

## Non-vacuity transcript (--self-test)

```
$ python3 scripts/private_trip.py --self-test
PRIVATE-TRIP self-test: REFUSE witnessed (home-path + env token) — gate non-vacuous
exit: 0
```

Mechanism: temp dir + planted `/Users/nobody/probe` line and planted env
token `tripwire_secret_token`; scan logic must produce both hit kinds, else
exit 2 (VACUOUS GATE). First real-tree run also proved the fail-closed
refuse path on an unreadable (worktree-deleted) file (exit 1, loud).

## Real-tree gate transcript (honest RED for triage)

```
$ just private-trip   # (via python3 scripts/private_trip.py)
PRIVATE-TRIP self-test: REFUSE witnessed (home-path + env token) — gate non-vacuous
PRIVATE-TRIP REFUSE: 41 hit(s) in 27 file(s)
  /Users/sac/smalt/popcorn_demo/lib/popcorn_demo/live_acr.ex:5: [home-path]   Face audit (2026-10-20, repo /Users/sac/smalt):
  ... (39 lines elided here; full list in gate stdout / this session transcript) ...
exit: 1
```

Full 41-hit list (file:line), grouped for triage — NO deletions performed:

**Class A — hardcoded `/Users/sac/smalt` repo-root constants in scripts (15, mechanical fix: derive from script dir / env):**
`scripts/bench/impl17_amqp_reductions.exs:13`, `scripts/bench/ja9_scaling.exs:12`,
`scripts/bench/pb2_reductions_step.exs:42`, `scripts/bench/pb6_dual_boundary.exs:19-23`,
`scripts/bench/pb6_wire_leg.mjs:18-19`, `scripts/bench/scvd_tier2.mjs:12`,
`scripts/bench/scvd_tier3.mjs:17`, `scripts/bench/sqld8_ingest_baseline.sh:7`,
`scripts/bench/pb5_crosslang.sh:5`, `scripts/demo_migration_rehearsal.sh:21`,
`test/courts/court_wire.erl:35`, `test/integration/fixtures/sqld2/generate_dump.exs:128`,
`test/integration/gld5fix_roundtrip_court.exs:24,203`,
`test/integration/sqld2_sql_ingest_court.exs:9,255`.

**Class B — absolute paths in comments / quoted run commands (13, cosmetic, repo-self paths):**
`popcorn_demo/lib/popcorn_demo/live_acr.ex:5`, `scripts/bench/ctq2_txn.mjs:19`,
`scripts/bench/impl17_amqp_reductions.exs:6`, `scripts/bench/pb2_reductions_step.exs:26`,
`scripts/bench/sqld8_ingest_baseline.exs:98`, `scripts/witness_all.py:20`,
`test/integration/amqp10_ledger_owner_court_test.exs:22`,
`test/integration/amqp_kd131_133_triage_test.exs:29`,
`test/integration/gld5fix_roundtrip_court.exs`, `test/integration/ja12_hot_reload_court.exs:2,14`,
`test/integration/ja13_supervisor_intensity_court.exs:12`,
`test/integration/ja7_crash_only_court.exs:27`, `test/integration/kd155_delete_framing_test.exs:31`,
`test/integration/sj1_journal_sink_court.exs:2`, `test/internal/amqp_listener_cap_test.exs:12`.

**Class C — external repo path `/Users/sac/graphlaw` (5, highest sensitivity):**
`scripts/witness_all.py:36` (`GRAPHLAW = "/Users/sac/graphlaw"`),
`test/integration/wasm_real_runner_court.exs:22,24,25,37`.

## Falsifier / close condition

Gate goes green (exit 0) when Classes A–C are remediated (env-derived roots,
relative paths, comment rewrites); then wire into `just court` per PRD.
Re-planting any `/Users/<name>/` or `PRIVATE_TRIP_TOKENS` token in a source
file must flip the gate to exit 1 — witnessed by `--self-test`.
