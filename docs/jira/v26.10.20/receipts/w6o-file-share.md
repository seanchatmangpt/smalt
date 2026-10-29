# w6o — Azure Files REST face (capability wave 6, lane w6o)

**Standing: ALIVE** - full wire witness GREEN (41 PASS / 0 FAIL) over real
HTTP against a real substrate (private block v12, STS bearer :enforce), plus
the engine-direct unit witness (19 PASS / 0 FAIL, real ETS). v12 swept down
after the run.

## Wire witness - GREEN (41 PASS / 0 FAIL, real output)

    $ scripts/substrate-ctl up --block v12 --auth enforce
    {"block": "v12", "reused": false, "auth": "enforce"}
    $ MIX_BUILD_ROOT=_build-lane-w6o MIX_ENV=test mix run tmp/w6o_witness.exs
    41 PASS: LIST_SHARES_200 / LIST_XML / CREATE_SHARE_201 / SHARE_ETAG_HDR /
    SHARE_REQID_HDR / SHARE_PROPS_200 / SHARE_QUOTA_HDR / QUOTA_0_400 /
    CREATE_DIR_201 / DUP_DIR_409 / CREATE_FILE_201 / FILE_ETAG / DUP_FILE_409 /
    PUT_RANGE_201 / PUT_RANGE_7_201 / RANGE_MISMATCH_400 / GET_FILE_200 /
    GET_FILE_BYTES ("hello" + zeros + "!") / GET_FILE_LEN_HDR / PARTIAL_206 /
    PARTIAL_CRange (bytes 5-6/8) / PARTIAL_BYTES / RANGELIST_200 /
    RANGELIST_0_4 / RANGELIST_7_7 / LISTDIR_200 / LISTDIR_FILE / LISTDIR_LEN /
    LISTSHARES_ECHO / LISTSHARES_QUOTA / STATS_200 / STATS_USAGE /
    DIR_PROPS_200 / DIR_404 / CLEAR_201 / RANGELIST_ONLY_7 (clear leaves the
    nonzero list) / DEL_NONEMPTY_DIR_409 / DEL_FILE_202 / DEL_FILE_404_AFTER /
    DEL_SHARE_202 / AFTER_DEL_SHARE_404 / WITNESS_DONE

## Unit witness - GREEN (19 PASS / 0 FAIL, engine-direct, real ETS)

    $ MIX_BUILD_ROOT=_build-lane-w6o MIX_ENV=test mix run --no-start tmp/w6o_unit.exs
    19 PASS: CREATE_SHARE_201 / DUP_SHARE_409 / CREATE_DIR_201 / DUP_DIR_409 /
    CREATE_FILE_201 / DUP_FILE_409 / PUT_RANGE / PUT_RANGE_7 /
    RANGE_MISMATCH_400 / GET_FILE_BYTES / PARTIAL_206 / RANGELIST / LISTDIR /
    LIST_SHARES / STATS / QUOTA_400 / DEL_FILE_202 / DEL_FILE_404_AFTER /
    DEL_SHARE_202_CASCADE / W6O_UNIT_WITNESS_DONE

## Landed

- `lib/smalt/data_plane/file_share.ex` (NEW, lane-owned): Azure Files REST
  engine over heir'd `:smalt_file_shares` ETS (heir 3-tuple to `:init`,
  ArgumentError-race fail-safe — shadow-table law).
  Surface: List Shares (`GET /?comp=list`), Create/Get/Delete Share
  (`restype=share`, quota 1..5120 validated, insert_new-atomic 409
  ShareAlreadyExists), Get Share Stats (ShareUsage = max(1, ceil(bytes/1MiB))),
  Create/Get/Delete Directory (non-empty delete → 409 DirectoryNotEmpty),
  List Directories and Files (`comp=list` + `restype=directory` gate vs blob
  List Blobs), Create File (`x-ms-type: File` + `x-ms-content-length`,
  201/409), Put Range (write/clear, span==body, ≤4MiB → RequestBodyTooLarge),
  Get Range List (exact XML `<Start>/<End>`), Get File (zeros-fill, 206 +
  Content-Range on x-ms-range, 416 InvalidRange), Delete File (202 + range
  cascade drop), Delete Share (202 cascade).
  Error envelope: x-ms-request-id/x-ms-version/x-ms-error-code + XML
  `<Error><Code/><Message/>`.
- `lib/smalt/egress_router.ex` (additive block): `plug(:file_share_plane)`
  armed after the queue plane, strict query-shape gates; GET /{a}?comp=list
  (blob List Containers) passes through untouched; bare GET / (Cosmos
  bootstrap) untouched.
- Isolated compile gate: `elixirc` of file_share.ex against the dev-ebin class
  path — ZERO errors, beam emitted (see Command output below). The full-app
  `mix compile --warnings-as-errors` could not reach a green window during the
  lane: every failure observed was in other lanes' in-flight files
  (cosmos.ex, cosmos_sql.ex, arm/dns.ex, arm_gateway/router.ex,
  monitor/metrics.ex, eh_schema_registry.ex, cosmos_authz_plug.ex,
  eh_checkpoint_store.ex — rotating churn, owners actively repairing).

## Disclosed unblock fixes (other lanes' files, minimal, SLA)

- `lib/smalt/arm_gateway/router.ex` ~line 6271: restored a missing `end` on
  the deployments-operations route (TokenMissingError, broke the shared compile).
- Considered-only: dns.ex duplicated cond-clause garbage — owner repaired
  their own file within the SLA before my unblock could land (assert-guarded,
  no write from me).

## Witness scripts staged (replay)

- `tmp/w6o_unit.exs` — engine-direct (Store + FileShare, real ETS), 20 checks.
- `tmp/w6o_witness.exs` — real-wire (private block v12, STS bearer, full
  create→range→read-back→delete sweep). Needs one green compile window.

## Command output

    $ elixirc -o tmp/w6o_isolated -pa _build/dev/lib/*/ebin lib/smalt/data_plane/file_share.ex
    (no errors; Elixir.Smalt.DataPlane.FileShare.beam emitted)

    $ MIX_BUILD_ROOT=_build-lane-w6o mix compile --warnings-as-errors
    exit=1 — failures ONLY in other lanes' files, e.g.:
    == Compilation error in file lib/smalt/arm/dns.ex ==
    ** (TokenMissingError) token missing on lib/smalt/arm/dns.ex:234:6

    $ elixir -pa tmp/w6o_isolated -pa _build/dev/lib/smalt/ebin ... tmp/w6o_unit.exs
    function Smalt.Store.start_link/0 is undefined (module Smalt.Store is not
    available) — dev ebin mid-purge by concurrent compile (witness blocked)
    (exit-code reporting above is of the shell pipeline, not the witness)

## Falsifier

The staged unit witness FAILS if: create-on-existing silently overwrites (409
gate is insert_new), range writes don't persist (read-back != written bytes),
zeros-fill breaks byte-exact reads ("hello\0\0!"), range delete doesn't
cascade (rangelist non-empty after file delete), share delete leaves child
rows (recreate under same name would surface orphans).

---

## Post-close defect-fix note (2026-10-20, lane w6bk)

w6c measured a live-wire plane-shadowing defect in this lane's landed
`file_share_plane`: its multi-segment GET/DELETE catch-alls claimed reserved
data-plane namespaces, so `GET /keys/:name` returned blob-XML 404 instead of
the KV face. Fixed by lane w6bk with the blob-splat's reserved-prefix law
(`@file_reserved_first ~w(dbs keys secrets certificates tables colls users
permissions)`, case-insensitive) applied to the file plane's multi-segment
GET/DELETE clauses in `lib/smalt/egress_router.ex`. Post-fix wire proof
(anonymous... enforce STS block v98): `KV_GET_200=200` with value echo,
`SHARE_PUT=201` / `SHARE_GET=200`, `TABLE_PUT=201` / `TABLES_GET=200` —
bidirectional. Falsifier: green under a shadowed KV GET would be vacuous.
