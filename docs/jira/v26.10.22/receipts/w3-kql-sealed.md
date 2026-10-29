# W3 — KQL vectorized operators over sealed segments (v26.10.22)

**Standing: PARTIAL_ALIVE → engine-level ALIVE for the new operator set**
(bin / countif / sumif / in / in~ / dcount landed + courted over a real
sealed-segment corpus; full-app `mix test` gating is BLOCKED by an unrelated
lane's in-flight `lib/smalt/egress_router.ex` syntax break — see
Compile-freeze disclosure below; court run standalone-compiled with real
deps, exit 0).

Context: solo

## What landed (additive, lib/smalt/data_plane/kql.ex)

| operator | shape | notes |
|---|---| courts |
|---|---|---|
| `bin(Col, dur)` | `summarize ... by bin(TimeGenerated, 1h)` and `extend/project` scalar | output column keeps the SOURCE column name (real Kusto behavior); DateTime/ISO8601 columns floor onto an epoch-ms grid, numeric columns floor numerically, non-parseable → nil (Kusto null propagation); reuses the shared duration grammar |
| `countif(pred)` | `summarize countif(severity > 3)` | full where-clause predicate AST per group (reuses `eval/3`) |
| `sumif(expr, pred)` | `summarize sumif(severity, severity > 3)` | Kusto argument order; sums only predicate-passing rows, Kusto null semantics on non-numeric |
| `in` / `in~` | `where device in ("a","b")` | `in` exact, `in~` case-insensitive; null never matches; fail-closed typed errors on malformed lists |
| `dcount(Col)` | `summarize dcount(device)` | distinct non-null terms per group (MapSet) |
| `bin` by-key | output column = source column name | groups floored to bin grid; correct per-hour rows |

## Per-operator court (test/data_plane/kql_sealed_court_test.exs)

Corpus law: segments are sealed via the real JournalSink frame codec
(`encode_frame/6` + meta.json sha256 manifest + `.seal` sentinel) into
`<dir>/sealed/`, then the corpus is exactly
`JournalReader.discover_sealed_segments/1` → `read_sealed_segment/1`
output — active/unsealed segments excluded by construction (C1 writes an
unsealed segment into `sealed/` and the reader quarantines it, loudly, per
the SPOF-A3 completeness law; it never enters the query corpus).

Command (standalone compile; full-app compile blocked by egress_router):

    PATH="$HOME/.asdf/shims:$PATH"
    elixirc -o /tmp/w3-ebin lib/smalt/data_plane/kql.ex \
      lib/smalt/storage/journal_sink.ex lib/smalt/storage/journal_reader.ex
    args=(); for d in _build/dev/lib/*/ebin; do args+=( -pa "$d" ); done; args+=( -pa /tmp/w3-ebin )
    elixir "${args[@]}" /tmp/w3-run.exs   # ExUnit runner over the court file

Court output (exit 0, 5/5 passed, real per-operator receipts):

    Running ExUnit with seed: 945394, max_cases: 32
    ..... (5 tests)
    Finished in 0.05 seconds
    Result: 5 passed        EXIT=0

  - C1 `bin`: 4 sealed events (3 in hour H, 1 in H+1) + 1 unsealed →
    `summarize count() by bin(TimeGenerated, 1h)` returns
    `[%{TimeGenerated => H, count_ => 3}, %{TimeGenerated => H+1, count_ => 1}]`;
    unsealed segment quarantined, never queried.
  - C2 `countif`/`dcount`/`sumif`: 5 sealed events →
    `where severity > 2 | summarize countif(severity > 3), dcount(device)` =
    `{countif_ => 3, dcount_device => 3}`; `summarize sumif(severity, severity > 3)` = 13
    (4+5+4 over the full corpus, Kusto predicate-first null semantics).
  - C3 `in`/`in~`: `device in ("alpha","gamma")` → 2 rows exact;
    `device in~ ("ALPHA","GAMMA")` → 3 rows (folds ALPHA).
  - C4 ratchet: `| frobnicate` → `SYN0004: unknown pipeline operator`;
    `mvfy(...)` → `SYN0004: unknown function`; `weirdif(...)` →
    `SYN0004: unknown aggregate function`; `severity inx (1,2)` → typed
    SYN- parse refusal. Fail-closed ratchet holds with the new operators in
    the accepted set (a gate that admits unknown operators is VACUOUS —
    this is the non-vacuity witness).
  - C5 falsifier (corpus bound): two disjoint sealed segments; same query
    `where severity > 2 | summarize countif(severity > 3), dcount(device)`
    gives `{0, 2}` on seg-A (severities 3,3) and `{4, 4}` on seg-B
    (severities 4,5,4,5) — different counts per segment, proving the query
    executes over the segment corpus, not a constant. Combined corpus: {4, 6}.

## Regression check (test/data_plane/kql_test.exs, standalone)

    Result: 9/11 passed

The 2 remaining failures are pre-existing ENVIRONMENT dependencies (the two
`Sentinel.ingest` tests hit `Smalt.Store` ETS tables that only exist when
the smalt app is booted; the standalone runner does not boot it) — typed
`ArgumentError ... does not refer to an existing ETS table`, NOT KQL
failures. The by-key regression they hid (plain `by Level` keys hitting the
new `by_value/3` dispatch) was caught and fixed during the run — the
witness query `where TimeGenerated > ago(1h) | summarize count() by Level |
sort by count_ desc` passes.

## Compile-freeze disclosure (SLA)

`lib/smalt/egress_router.ex` was and remains syntactically broken by
another lane's in-flight edit (unclosed delimiter at the
`ensure_put_blob_type` fn closure, ~line 1843/1962) — full-app `mix
compile` fails on THEIR file, freezing all lanes. I did NOT touch their
file (it changed under me mid-fix — owner is actively editing). Per SLA I
unblocked my lane by standalone-compiling only the modules I own plus the
two journal modules: `kql.ex` compiles clean (0 errors).

## Session-introduced fixes (disclosed)

  - `by_value/3` dispatch: plain `by <col>` keys are binaries (parser shape),
    `bin(...)` keys are `{:bin, col, dur}` — the naive `{:col, _}` clause
    broke the existing witness test; caught by real test output and fixed.
  - `bin_value/2` arity consolidation; `sumif` empty-group nil; warnings
    cleaned (unused `now`).

## Commands & exits

  - court (W3): exit 0 — `Result: 5 passed`
  - kql_test regression: 9/11 (2 pre-existing ETS-environment failures,
    both on Sentinel ingest, not KQL)
  - `mix compile` (full app, MIX_BUILD_ROOT=_build-w3): exit 1 on the
    unrelated lane's egress_router.ex — pre-existing, not session-introduced

## Falsifier status

  - corpus-bound falsifier (C5): RAN, holds (different segments →
    different counts).
  - unknown-operator ratchet (C4): RAN, holds (typed SYN0004).
  - full-app mix test gate: BLOCKED by the egress_router lane — must rerun
    `MIX_BUILD_ROOT=_build-w3 mix test test/data_plane/kql_sealed_court_test.exs test/data_plane/kql_test.exs`
    once that file compiles.
