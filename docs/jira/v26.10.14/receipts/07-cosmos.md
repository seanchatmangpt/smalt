# Receipt — V261014-07 (lane 07, cosmos)

- **Subject**: /Users/sac/smalt @ main, working tree (no commits; coordinator owns git), 2026-10-15
- **Work order**: docs/jira/v26.10.14/07-cosmos.md — decision gate taken: option (a) whitelist gate
- **Files touched**: `lib/smalt/data_plane/cosmos.ex`, `test/data_plane/cosmos_test.exs`, `docs/WIRE_PARITY.md`, `docs/compliance/C3_COSMOS.md`; deleted `lib/smalt/data_plane/cosmos.ex.lens3bak`

## Changes

1. **list_docs gate wrap**: body wrapped in `gate(:get, "docs", container_link(db, coll), headers, fn -> ... end)` — same auth/RU/consistency-echo wrap as every sibling doc route. Anonymous-mode default unchanged (authorize is a no-op outside `:enforce` + master key).
2. **nil-prefix normalization**: `prefix = scope(prefix)` at the top of `list_docs` — nil and "" are one continuation-token namespace; a nil feed can no longer mint `"nil/<id>"` tails it cannot consume.
3. **Restart court**: poll lengthened 500×10ms (~5s cap, CI flake) → 2000×50ms (100s ceiling), event-based on `Cosmos.store_ready?()`.
4. **lens3bak deleted**: `rm lib/smalt/data_plane/cosmos.ex.lens3bak` (plain rm — lane directive: no git state changes; deletion sits in the working tree for the coordinator). `grep -rn lens3bak --exclude-dir=deps --exclude-dir=.git .` now hits only the work order and `_LANES.md` prose.
5. **SQL whitelist honesty gate (option a)**: `do_query_docs/4` (now passing the trimmed query text) admits only the anchored, case-insensitive `^select\s+\*\s+from\s+[A-Za-z_][A-Za-z0-9_]*$` form; every other nonblank query answers typed 400 `SyntaxError` / "The query syntax is invalid." — never a silent partition scan. Blank/absent query → existing 400 BadRequest unchanged. 29 test literals (`"SELECT"`, `"SELECT 1"`, `"s"`) rewritten to `"SELECT * FROM c"` (400-expecting forged-token legs keep their fence intent).
6. **Docs**: WIRE_PARITY cosmos row + Coverage-boundaries prose state the whitelist gate (GAP label retained); C3_COSMOS known-deviation notes carry the tokenized `GAP(cosmos-sql-translator-absent)` + fenced-evidence pointer. No untokenized "no SQL translator" prose remains in C3.

## New courts (cosmos_test.exs, v261014-07 describes)

- 401 + WWW-Authenticate: Bearer on anonymous `GET /dbs/:db/colls/:coll/docs` through the real `EgressRouter` under `auth_mode: :enforce` (env saved/restored).
- nil-prefix round trip: mint under nil → token tail `2#<lsn>:<b64c>:n100` (no `nil/`); resume under nil AND under "" → 200 + remaining 5 docs.
- Whitelist court: `SELECT * FROM c` → 200 feed; `WHERE`/`ORDER BY`/`JOIN`/`TOP`/projection/`"s"`/`DROP TABLE c` → 400 `SyntaxError` + request-charge header.

## Verification (real output)

- `mix compile` — clean.
- `mix test test/data_plane/cosmos_test.exs` → **105 tests, 0 failures**
- `mix test test/compliance/c3_cosmos.exs test/data_plane/cosmos_test.exs` → **133 tests, 0 failures**
- Restart court × 10 consecutive: 10 × `1 test, 0 failures (104 excluded)`
- lens3bak grep: only work-order/_LANES prose hits (file gone from tree).

## Conflict disclosure

Lane 01 (test-isolation) applied a compile-freeze unblock to my in-flight `do_query_docs` rename (disclosed in-file in cosmos.ex); I folded it in as-is (message "The query syntax is invalid.") and pinned the exact message in the whitelist court. WIRE_PARITY blob row (:124, lane 06) untouched — edits were scoped to the cosmos row and Coverage boundaries only.

## Standing

V261014-07 items 1–6: ALIVE (all acceptance courts executed green on the live tree). `GAP(cosmos-sql-translator-absent)` remains open by design — the whitelist narrows the lie, it does not close the gap.
