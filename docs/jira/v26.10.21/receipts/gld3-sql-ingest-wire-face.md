# GLD-3 — SQL Ingestion Wire Face (POST /sql-ingest)

**Standing: PARTIAL_ALIVE** — 201/422/400 wire faces witnessed over real HTTP
(Bandit + :httpc court + live curl transcript); composition with GLD-6's
`SqlRowGate` live on the wire; one known cross-lane defect (multi-table DDL
refused by GLD-6's gate, their file) plus two SQLD-2 parser quirks registered
below.

**Context: solo** (internal-tier court, in-process Bandit + :httpc loopback;
live curl witness on private port 39941, listener torn down after).

## Files (this lane's diff)

- `lib/smalt/egress/SqlIngestRoutes.ex` (NEW, mine) — w6R-split delegator:
  `post "/sql-ingest"` → validate `{format, mapping_iri, data_b64}` →
  base64 decode → `Smalt.SqlIngest.parse_dump/1` → GLD-6
  `Smalt.GraphLaw.SqlRowGate.check/2` (added to my `run_pipeline` by the
  GLD-6 lane mid-session, consumes my `andon_refusal/6` via
  `{:refusal, %{rule_id, diagnostic, repair_hint, digest_term}}`) →
  OCEL projection (`Smalt.Ocel` envelope shapes, validated with
  `Ocel.validate_envelope/2` before send) → 201 summary.
- `lib/smalt/egress_router.ex` — one-line seam edit: appended
  `Smalt.Egress.SqlIngestRoutes` to the w6r_fallthrough mod list (~line 897),
  with comment. No other change.
- `test/internal/sql_ingest_wire_court.exs` (NEW, mine) — Chicago court.

## Wire contract

- `201` → `{"status":"ingested","format","mappingIri","tables":[{name,
  columns, rowCount}],"ocel":{"eventCount","objectCount"}}`
- `422` → GL-8 `GraphlawRefusal` andon envelope
  (`AndonWire.http_envelope/2`): code/rule_id/diagnostic/agent_message/
  repair_hint/context_digest/session/ts/json_ld +
  `x-ms-error-code: BusinessLawViolation`. Rules observed on the wire:
  `sql.injection_token` (poisoned COPY target), `sql.shape_generation`
  (no DDL), `sql.shacl_row` (datatype/closed violations; GLD-6).
- `400` → `InvalidSqlIngestRequest` / `InvalidDataEncoding` /
  `UnsupportedSqlFormat` (only `postgres_dump` wired; `csv`/`sqlite` loud
  typed 400, never 404).

## Court (real transport, no mocks)

```
$ MIX_BUILD_ROOT=_build-gld3 mix test test/internal/sql_ingest_wire_court.exs
...
Finished in 0.1 seconds (0.00s async, 0.2s sync)

Result: 3 passed
```

(also verified 0 occurrences of `AlreadySentError` in the court log — the
kd07-class sent-but-not-halted leak is fenced by `halt_if_sent/1`; this
delegator is LAST in the fallthrough chain.)

## Wire witness (live curl, real Bandit listener on 39941, anonymous mode)

201 leg:

```
HTTP/1.1 201 Created
content-type: application/json; charset=utf-8

{"format":"postgres_dump","mappingIri":"https://example.com/mapping/witness-1",
 "ocel":{"eventCount":1,"objectCount":2},"status":"ingested",
 "tables":[{"columns":["id","kind"],"name":"events","rowCount":2}]}
```

422 leg (injection-token COPY target `"users; DROP TABLE users; --"`):

```
HTTP/1.1 422 Unprocessable Content
x-ms-error-code: BusinessLawViolation

{"error":{"code":"GraphlawRefusal","rule_id":"sql.injection_token",
 "diagnostic":"COPY target \"\"users;\" carries SQL metacharacters",
 "repair_hint":"table name ... failed the identifier guard; rename ... and re-POST",
 "context_digest":"1a7685a16a83265581d793a56239e1a966c159d0303fa0cadaffba969a31a301",
 "ts":1792628560416520542, ...}}
```

Additional live refusals witnessed: `sql.shape_generation` (dump with no
CREATE TABLE DDL), `sql.shacl_row` (bigint column given a non-integer value).
400 leg: `format:"sqlite"` → `400 UnsupportedSqlFormat`.

## Compile-freeze disclosures (same-checkout fan-out)

1. **`lib/smalt/sql_ingest/mapping.ex` (SQLD-4's file)** — minimal unblock
   fix under the compile-freeze SLA after the shared compile was frozen
   10+ min: string-literal keys are not valid typespec map syntax, so
   `to_cold1_csvs`'s @spec became `%{optional(String.t()) => String.t()}`.
   Their lane should re-pin when they next touch the file.
2. **GLD-6 edited `SqlIngestRoutes.ex` (my file)** — added the
   `SqlRowGate.check/2` step to `run_pipeline` and a `{:refusal, ...}`
   else-clause. The edit is correct and composes with my
   `andon_refusal/6`; the live wire transcript above was taken WITH their
   gate active. Disclosed per the compile-freeze disclosure law.

## Cross-lane findings (not fixed by this lane — owners' files)

- **GLD-6 `SqlRowGate.schema_from_ddl/1`** refuses a valid multi-table dump:
  with two CREATE TABLE statements the shape for the second table loses its
  columns ("closed violation on column k: unknown property path k" for a
  clean `CREATE TABLE kinds (k text, v bigint)`); witnessed in the court
  (now single-table fixture) and live. Multi-table 201s are blocked on their
  fix.
- **SQLD-2 `SqlIngest.parse_dump/1`** keys tables by BARE name
  (schema qualifier stripped): `public.events` and `events` collide on one
  map key (last block wins). Fixture avoids the collision; a KD row may be
  warranted.
- **SQLD-2 mid-field `\N`**: `2\Nfinish` unescapes to `"2Nfinish"` — the
  backslash-N escape is swallowed mid-field instead of decoded literally
  (only whole-field `\N` → null is handled; mid-field `\N` hits the escape
  map with no "N" entry and is dropped).

## Toolchain / environment

- OTP 29.1.2 + Elixir 1.20.4-otp-29 (asdf, repo `.tool-versions`); shared
  compile frozen twice mid-session by sibling lanes' in-flight files
  (`journal_sink.ex` delimiter error, then `mapping.ex` typespec) — resolved
  by their edits + disclosure 1 above. `MIX_BUILD_ROOT=_build-gld3`.
- Live witness listener torn down (port 39941 free); scratch files removed.
