# GLD-5FIX — F2/F3 close + F1 pin + value-exact round-trip court (v26.10.21)

- **Date**: 2026-10-21
- **Lane**: GLD-5FIX (writer, OTP-29 toolchain: Elixir 1.20.4-otp-29, Erlang/OTP 29.1.2)
- **Repo**: /Users/sac/smalt @ main e4864b4 (+ in-flight SQLD wave files)
**Standing**: ALIVE — F2 and F3 are closed on the newest text with real-duckdb witnesses;
  F1's witnessed flip is pinned; the wave's missing value-exact court exists and passes.
- **Context**: solo

## Diff (manufactured this lane)

`lib/smalt/sql_ingest.ex` (+89/−9):

1. **F2 — typed NULL sentinel, lossless by construction.** `csv_field(:null)`
   now emits bare `\N` (was `""`); empty string emits quoted `""`; a literal
   `\N` VALUE (produced by COPY escape `\\N`) is force-quoted `"\N"` so it can
   never alias the sentinel. Wire contract documented in @moduledoc: consumers
   must load with `read_csv(..., nullstr='\N', allow_quoted_nulls=false)`.
   `allow_quoted_nulls=false` is load-bearing: duckdb 1.4.1 with explicit
   nullstr matches quoted fields too (witnessed: quoted `"\N"` loaded as NULL
   until the flag was set; after: `\N`→NULL, `""`→empty, `"\N"`→literal —
   three distinct tokens, all lossless).
2. **F3 — formula-injection neutralization.** Fields with leading
   `=`/`+`/`@`/`-` get the spreadsheet-standard `'` prefix, EXCEPT valid
   numeric literals (regex `^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$`): a
   spreadsheet evaluates those as numbers, never formulas, so prefixing them
   would break value-exact round-trips (`-0.0`, `3.10`, `1e-3`, `+1` pass
   byte-exact). Documented in @moduledoc as the OWASP CSV-injection mitigation.
3. F1 pin: covered by the new court leg 1 (below), plus the pre-existing
   SQLD-2 leg 6.
4. `@spec parse_dump` rows typed `[String.t() | :null]`.

`test/integration/gld5fix_roundtrip_court.exs` (new, 6 legs):

- **Leg 1 (F1 pin)**: `COPY public.t; DROP TABLE secrets-- (a) FROM stdin;`
  → `{:error, {:injection_token, "t;"}}` — the exact flip GLD-5 witnessed,
  fenced; quoted-identifier header refused whole as well.
- **Leg 2**: hostile corpus (6 rows x 6 cols) parses back EXACTLY
  (incl. `:null`); non-vacuity: corpus contains a real NULL.
- **Leg 3**: CSV wire-bytes contract — `\N` / `""` / `"\N"` distinct;
  `'=cmd|'/c no'!A1`, `'+1+1`, `'-1+1`, `'@SUM(1)`, `'=1+1`, `'@x`, `'-`
  neutralized; `,=cmd` absent (non-vacuity).
- **Leg 4**: real `/opt/homebrew/bin/duckdb` (v1.4.1) `read_csv` load,
  `nullstr='\N', allow_quoted_nulls=false`, 0 errors.
- **Leg 5**: per-row value-exact assertions INSIDE duckdb — every row's every
  field (NULL typed as NULL, all others exact string equality), 6/6 rows, 1
  unique match each, total count 6/6 (zero row loss).

## Commands + real output

```
$ elixir test/integration/gld5fix_roundtrip_court.exs     # (both 1.19.5-otp-28 and 1.20.4-otp-29)
leg1 F1 pin: malformed COPY header refused {:injection_token, "t;"}
leg1b F1 pin: quoted-identifier injection target refused: "\"users;" (whole header refused, nothing ingested)
leg2 hostile corpus: 6 rows parsed, parse_dump == corpus exactly (incl. :null)
leg3 CSV wire: \N / "" / "\N" distinct; formula payloads neutralized ('=cmd, '+1+1, '-1+1, '@SUM); numerics byte-exact (-0.0, 3.10, 1e-3, +1)
leg4 duckdb load: read_csv(nullstr='\N') over 6-row hostile.csv, 0 errors
leg5 rows 1-6: value-exact in duckdb (1 unique match, NULL/empty/typed cells)

GLD5FIX COURT: PASS
corpus: /Users/sac/smalt/tmp/gld5fix/hostile.csv (6 rows x 6 cols), sha256: 299e042b9ada011d625e6bd2d2a454289d64af011ff21cb9549fe2ae85c500dd
nulls: wire-\N -> duckdb NULL; empties: wire-"" -> ''; zero row loss (6/6)
formula neutralization: 7 payloads prefixed, 6 numerics byte-exact
F1 pin: {:injection_token, "t;"} on malformed header (GLD-5 witnessed flip, fenced)
```

```
$ elixir test/integration/sqld2_sql_ingest_court.exs
leg2 converter: counts=... (500 rows), columns exact
leg3 duckdb: 120/300/80 = 500 typed rows loaded; referential + domain integrity 0 violations
leg4 OCEL v2: 80 events / 420 objects / 380 rels, 0 dangling rels
leg5 excursion: duckdb == Elixir re-derivation, n=11 orders: O-100, O-111, O-162, O-166, O-206, O-251, O-253, O-299, O-32, O-60, O-8
leg6 SHACL gate: injection-token table refused; whole-parse fail-closed
SQLD2 COURT: PASS   (sha256 c5c65bd1533917...eed1990 — identical legs, still green on the new encoding)
```

```
$ MIX_BUILD_ROOT=_build-gld5fix mix compile            # OTP-29 toolchain, exit 0
$ MIX_BUILD_ROOT=_build-gld5fix mix test test/internal/sql_ingest_wire_court.exs
Result: 1/3 passed, Failed: 2 tests
$ # identical 1/3 on HEAD's sql_ingest.ex (swapped via git show > file, byte-restored):
$ tail -3 /tmp/wirecourt_head.log
Result: 1/3 passed, Failed: 2 tests
```

The 2 wire-court failures are PRE-EXISTING, not session-introduced: the working
tree's `lib/smalt/egress_router.ex` (another lane's in-flight edit) raises
`Plug.Conn.AlreadySentError` at `blob_route/2` (egress_router.ex:2690) on every
POST, and the 201 leg expects two table objects for two COPY blocks that key to
the same bare name (`public.events` + `events` → one map key) — a
table-key-collision behavior outside GLD-5's kill list. Zero regression from
this lane's diff (HEAD and fixed text behave identically on that court).

## Honest failures / disclosures

- duckdb v1.4.1 with explicit `nullstr` matches QUOTED fields (contrary to the
  common assumption); only `allow_quoted_nulls=false` makes the encoding
  lossless. This was caught by the court itself (leg5 row 4 `"\N"`→NULL), i.e.
  the court the wave lacked did its job during authoring.
- Compile-freeze disclosure: the wire-court failures named above trace to
  another lane's in-flight `lib/smalt/egress_router.ex`; not touched by this
  lane (read-only for that file, pattern-match verified HEAD==fixed there).
- Lane build root `_build-gld5fix` left in place (lane lease; coordinator
  deletes at integration).

## Replay

```
export PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
elixir test/integration/gld5fix_roundtrip_court.exs   # PASS expected
elixir test/integration/sqld2_sql_ingest_court.exs    # PASS expected
MIX_BUILD_ROOT=_build-gld5fix mix test test/internal/sql_ingest_wire_court.exs  # 1/3, pre-existing
```

## Falsifier

Revert `csv_field(:null)` to `""` (or drop `allow_quoted_nulls=false` from the
load): leg5 row-count/NULL-distinction assertions fail loudly. Drop the `'`
prefix: leg3's `not contains(",=cmd")` fails loudly. Revert the malformed-header
refusal: leg1 fails loudly.
