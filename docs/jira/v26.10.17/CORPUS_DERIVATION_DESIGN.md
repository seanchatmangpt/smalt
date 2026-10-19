# CORPUS_DERIVATION_DESIGN

Window: v26.10.17 — design study only, nothing implemented, no GAP token minted.

## Problem

Compliance-corpus premise rot is caught today by courts (c1–c7 fence suites)
and hand-maintained md rows, not by a build failure. `docs/ERROR_CODES.md`
already solves this class of problem for error envelopes: it is a projection
of `lib/` via `scripts/gen_error_codes.py` with a byte-identity `--check`
drift fence (`test/error_codes_doc_test.exs` fails on drift). The question:
how far can **corpus expectations** (error code, HTTP status, header set per
surface) be projected from the same `lib/` annotations, so that changing a
lib/ literal that a corpus row pins breaks the build instead of a court?

## Existing derivation substrate (reuse, don't duplicate)

`scripts/gen_error_codes.py` already extracts, per surface:

- `send_arm_error(conn, status, code, ...)` call sites (ARM router), LRO
  terminal envelopes, policy 400, bearer `{:refuse, "Code", _}` sub-codes,
  egress literal error envelopes, CLI-gateway 403.
- `extract_data_plane()`: the six data-plane modules (`sentinel`,
  `resource_graph`, `purview_atlas`, `key_vault_actions`, `cosmos`,
  `confidential_ledger`) — pairs each `{:error, <literal 3-digit status>, ...}`
  opener with the first `"code" => "..."` literal within a 300-char window,
  after stripping comments and `@doc` strings (phantom-row prevention).
- `extract_compliance()`: codes asserted by `test/compliance/*.exs`.

Fences already in place: `--check` byte-identity (exit 1 on drift),
`mix smalt.gen` byte-identical replay tests, Canonical.write riders
(`docs/capabilities.json`, `docs/THIRD_PARTY.md`).

## Classification of corpus row classes

### D1 — mechanically derivable today

**Error code + literal HTTP status per envelope site.** Every (surface,
method, route, status, code) literal pair gen_error_codes.py witnesses is a
pure function of `lib/`. A corpus row asserting "PUT doc, stale If-Match →
412 PreconditionFailed" is derivable wherever both literals are static in
lib/. The corpus row becomes a read of a generated expectation table instead
of a hardcoded literal.

### D2 — maybe (per-surface design required)

**Header-set invariants** (cosmos `x-ms-request-charge`/`x-ms-session-token`/
`x-ms-lsn`/`x-ms-alt-content-path` — C3 row 1; blob `x-ms-version`,
`x-ms-request-id` v4-GUID pin at `c4_blob.exs:85/:220`). Derivable only where
a single named function centralizes the header set (`cosmos.ex`
`success_headers` at cosmos.ex:465-478, `egress_router.ex` `cosmos_respond`
at 1361-1373): the generator emits (header-set-id, sorted header names) from
that function; value shapes (v4-GUID regex, quoted-64-hex etag) stay as an
ANNOTATIONS-style table in the generator, marked `[annotation]`. Where headers
are added ad hoc at call sites (parts of C4 row 1), the row is NOT derivable —
it keeps a `HAND` marker until the header set is centralized.

### B — behavioral (out of scope, permanently court-fenced)

Sequences and state: LRO emit→resume→terminate, continuation-token
emit→resume (C3 row 18), CAS exactly-one-winner races
(`gates/cosmos_etag_cas_gate.py` capture), 8-way duplicate-create 409 race
(C3 row 19), throttling windows (C3 row 13), monotonic `_ts`/LSN/session
tokens (C3 rows 2/12). Derivation stops at the wire envelope; behavior stays
with `mix test test/compliance/*` and `gates/*`.

## Generator shape

`scripts/corpus_projection.py`:

- imports the `gen_error_codes.py` extractor functions — one extractor, two
  projections (the doc, the corpus module). No second copy of the regexes.
- walks route tables (ARM `@actions`, egress router clauses) to attach each
  envelope site to a (method, route-pattern) key.
- emits `test/support/generated/corpus_envelopes.ex` — generated Elixir
  module `Smalt.CorpusEnvelopes` with an `@envelopes` module attribute and
  `expectations(surface, method, route)` accessors; same module-attribute
  pattern as the `mix smalt.gen` outputs (`lib/smalt/registry.ex`,
  `lib/smalt/config.ex`), so the byte-identical replay fence applies as-is.
- emits a human-readable rider `docs/CORPUS_ENVELOPES.md` <!-- [stale-path] never landed; see docs/jira/v26.10.17/CORPUS_DERIVATION_DESIGN.md (this design doc) --> (ERROR_CODES.md
  pattern).
- `--check` mode: byte-identity against both outputs, exit 1 on drift, with a
  unified-diff hint (gen_error_codes.py `diff_hint` pattern).

## Fence command + non-vacuity

```bash
just corpus-projection            # generate
just corpus-projection --check    # exit 1 on drift
```

- Fence test `test/corpus_projection_check_test.exs` shells `--check` and
  fails on drift (pattern of `test/error_codes_doc_test.exs`).
- Anti-vacuity leg (mandatory, gates/common.py negative-fixture pattern):
  mutate a status literal in a temp copy of a data-plane module → `--check`
  must exit 1. A fence that cannot exit 1 on a real mutation is the failure.

## Corpus seam

c1–c7 suites stop hardcoding `assert status == 412` /
`assert body["code"] == "PreconditionFailed"` where the row is class D1 and
read `CorpusEnvelopes.status_for(...)` / `code_for(...)` instead. Effect:
lib/ envelope-literal change + stale corpus row = build failure at
`--check`/replay time, before any test runs. D2 rows adopt per surface as
header sets centralize; B rows are untouched.

## Rollout order

1. Extract: refactor `gen_error_codes.py` extractors to be importable
   (pure functions, no side effects at import) — zero behavior change,
   `--check` must stay green.
2. Generate: `corpus_projection.py` emits TSV + `Smalt.CorpusEnvelopes` +
   rider md; byte-identity fence lands with the anti-vacuity leg.
3. Migrate: c-suites read D1 expectations from the generated module, one
   compliance file per PR, each with its normal `mix test` court receipt.
4. D2 adoption: only after the named header-set function exists in lib/
   (centralization is a lib/ change, not a generator change); `HAND` marker
   drops per row.
5. B rows: never migrate; documented as out of scope in the rider.

## Falsifier

A lib/ status/code literal is edited and the corpus still passes all suites
without `corpus-projection --check` failing → the derivation seam is vacuous
and must be repaired before further D1 migration.
