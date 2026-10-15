# V261014-07 — Cosmos Data Plane: gate wrap, token hygiene, SQL honesty gate, dead-file cleanup

- **Release:** v26.10.14
- **Files owned:** `lib/smalt/data_plane/cosmos.ex`, `test/data_plane/cosmos_test.exs`, `docs/WIRE_PARITY.md`, `docs/compliance/C3_COSMOS.md`
- **Status at open:** continuation-token v2 namespaces fully fenced — no work. Five defects remain, in implementation order.
- **Decision gate (item 5):** option (a) whitelist gate — RECOMMENDED.

## 1. `list_docs` bypasses `gate/5` — no auth / RU-throttle on list feed

**Evidence:** `cosmos.ex:496-533`. All sibling routes gate: `create_doc` (:246), `get_doc` (:324), `put_doc` (:369), `delete_doc` (:444), `query_docs` (:545). `list_docs` runs `store_ready?()` directly with no `gate/5` wrap, so `GET /dbs/:db/colls/:coll/docs` performs no auth and no RU accounting.

**Fix:** wrap the `list_docs` body in `gate(:get, "docs", container_link(db, coll), headers, fn -> ... end)`, matching the sibling shape (list feed is container-scoped, same as query/create).

**Acceptance:**
- 401-without-auth fence on `GET /dbs/:db/colls/:coll/docs` (new court mirroring the sibling fence).
- All existing list-feed tests stay green (reuse whatever auth headers sibling tests use).
- Continuation courts unchanged: forged/unlawful tokens still 400.

## 2. nil-prefix continuation-token self-poisoning

**Evidence:** `list_continuation_token/5` (:718-722) builds its tail with `if prefix == "", do: tail, else: "#{prefix}/#{tail}"`. With `prefix = nil` the else branch fires and the minted tail is `"nil/<last_id>"`; parse (:736) compares `tok_prefix == prefix` raw — a nil-prefix feed mints tokens its own feed cannot consume. The lens-8 test (`cosmos_test.exs:2189`) passes `nil` and *expects* 400, masking the poisoning with a passing test.

**Fix:** normalize at entry to both mint and parse, exactly like the query surface's `scope/1` (:697-698): `prefix = scope(prefix)` at the top of `list_docs` (or of both token functions). Reuse `scope/1` — no second normalizer.

**Acceptance:**
- Round-trip court: `list_docs(db, coll, nil, %{})` with >`@query_limit` docs → page 1 carries `x-ms-continuation`; resuming with that token under the same nil prefix returns 200 + remaining docs (not 400).
- `""` and `nil` prefix tokens are mutually acceptable (same namespace).
- Lens-8 court stays green (its junk tokens 400 via the lsn conjunct, not the prefix conjunct).

## 3. Restart-readiness poll has a 5-second cap — CI flake

**Evidence:** `cosmos_test.exs:2039-2070` polls `Cosmos.store_ready?()` 500 × 10ms (~5s) then asserts `restarted?`. Under CI load the supervisor restart can exceed 5s → flake. (Secondary: the only test restarting a shared supervised GenServer — safe within the `async: false` file.)

**Fix (prefer event-based):** wait until `Cosmos.store_ready?()` **and** a probe read confirms fresh tables, with no hard cap shorter than the CI budget; or lengthen to e.g. 2000 × 50ms. Check for an existing `wait_until` helper before hand-rolling.

**Acceptance:** 10 consecutive green runs of the restart court.

## 4. Shipped dead file — delete

`lib/smalt/data_plane/cosmos.ex.lens3bak` exists in the release tree (not compiled — `.ex.lens3bak` isn't `.ex` — but dead weight). `git rm` it; confirm `grep -rn "lens3bak" --exclude-dir=deps .` returns nothing after removal.

## 5. GAP(cosmos-sql-translator-absent) — SQL honesty gate

**Evidence:** `do_query_docs` (:578) discards the SQL text (`query_text/1` :563-576 validates only nonblank). Any nonblank query — `SELECT ... WHERE`, ORDER BY, JOIN, aggregates, or `DROP DATABASE c` — executes the same partition scan and returns an honest-*looking* 200. The emulator answers queries it did not evaluate.

**Decision gate:**
- (a) **Whitelist gate — RECOMMENDED:** admit only the trivial `SELECT * FROM <alias>` form; anything else answers a typed 400 `SyntaxError`/`InvalidQuery` like real Cosmos. Small: `query_docs`/`do_query_docs` + updating existing tests that pass `"s"`. Honors the honesty bar.
- (b) Full SQL translator — feature-scale, out of window.
- (c) Typed-UNSUPPORTED doc only — leaves the lying 200 in place; rejected.

**Fix under (a):** in `do_query_docs`, before scanning, run a strict anchored, case-insensitive, whitespace-tolerant whitelist match (`SELECT` `*` `FROM` alias; no WHERE/JOIN/ORDER BY/TOP/projections). On miss: `error_response(db, coll, 400, "SyntaxError", ...)`. Update existing tests passing `"s"` (e.g. :2032) to `"SELECT * FROM c"` — same fence intent.

**Acceptance (whitelist court):**
- `SELECT * FROM c` → 200 feed exactly as today (shape, partition scoping, continuation).
- `SELECT c.id FROM c WHERE c.x=1` → **400 typed**, never a silent scan.
- Garbage (`"s"`, `"DROP TABLE c"`) → 400 typed.
- Blank/absent query → existing behavior unchanged.

## 6. Docs — tokenize GAP prose

- `docs/WIRE_PARITY.md:133` and `:229`: update to state the whitelist gate; the `GAP(cosmos-sql-translator-absent)` label stays (the whitelist narrows the lie, it does not close the gap).
- `docs/compliance/C3_COSMOS.md`: currently carries un-tokenized GAP prose (see PARTIAL_ALIVE header ~:28-30) — tokenize in `GAP(...)` form and record the whitelist court as fenced evidence.

**Doc acceptance:** every GAP mention in both docs uses token form; no untokenized "no SQL translator" prose remains in C3.

## Implementation order & blast radius

1 → 2 → 4 (mechanical) → 3 (test-only) → 5 (behavior change + test updates) → 6 (docs last). Item 5 is the only wire-visible change. Existing green courts that must stay green: all continuation-token v2 courts, partition-scoped feed shape, `test/compliance/c3_cosmos.exs` row-18 court.
