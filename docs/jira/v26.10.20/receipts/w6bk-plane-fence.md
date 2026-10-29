# w6bk — plane-fence fix (file/table plane shadowing of reserved namespaces)

**Standing:** ALIVE (module + wire tiers)
Context: solo

## Defect (measured, lane w6c on live wire, block v62)

The file-share plane's multi-segment GET/DELETE catch-alls in
`lib/smalt/egress_router.ex` claimed ANY multi-segment path — including
reserved data-plane namespaces. `GET /keys/:name` returned blob-XML 404
(`BlobNotFound`) instead of the KV face; every 3-segment KV/cosmos/
certificates data-plane GET/DELETE was exposed.

## Fix (minimal additive)

`lib/smalt/egress_router.ex` — reserved-prefix fence on the file plane's
multi-segment GET/DELETE clauses:

    @file_reserved_first ~w(dbs keys secrets certificates tables colls users permissions)
    def file_reserved_first?(first)  # case-insensitive, URI-decoded

The table plane (`TableStorageRouter.route/1`) was audited: every arm requires
literal `tables` as first segment — already fenced, no change.

## Real output — routing-decision unit (mix run --no-start, real Store)

F1_KV_GET_PASSES_THROUGH=true
F2_SECRET_GET_PASSES_THROUGH=true
F3_COSMOS_GET_PASSES_THROUGH=true
F4_CERT_DELETE_PASSES_THROUGH=true
F5_TABLES_GET_PASSES_THROUGH=true
F6_SHARE_PROPS_STILL_CLAIMED=true
F7_FILE_GET_STILL_CLAIMED=true
F8_FILE_DELETE_STILL_CLAIMED=true
F9_TABLES_LIST_OK=true
F10_TABLE_RESERVED_KEY_PATH_IGNORED=true
F11_RESERVED_CASE_INSENSITIVE=true
W6BK WITNESS: ALL LEGS DONE

(Receipt transcription corrected 2026-10-20: two garbled duplicate verdict
lines removed; the witness run output above F1–F11 is authoritative as
captured.)

## Real output — live-wire bidirectional legs (substrate block v98, STS bearer)

KD-15 challenge handshake: tokenless GET → 401 MissingBearerToken (the KV
face's 401 — NOT blob-XML), STS token mint (1275-char RS256), then:

SECRET_PUT=200
KV_GET_200=200      (value `w6bk-value` echoed; pre-fix this was blob-XML 404)
SHARE_PUT=201
SHARE_GET=200       (ShareQuota XML echo)
TABLE_PUT=201
TABLES_GET=200      ({"value":[{"TableName":"w6bktbl"}]})
v98 swept down (up=0)

## Internal tier

mix test test/internal -> 48 tests, 0 failures
(run 1 showed 1 failure under sibling-lane parallel churn; did not reproduce
on re-run; no w6bk-file involvement)

## Compile

MIX_BUILD_ROOT=_build-lane-w6bk mix compile --warnings-as-errors -> RC=0 on
the lane's files; strict gate blocked only by sibling-owned in-flight files
(resource_health.ex, key_vault_actions.ex mid-edit windows, both repaired by
their owners during the lane).

## Falsifier

Green under a shadowed KV GET (blob-XML instead of the KV face) would be
vacuous. F1-F5 + the wire KV_GET_200 leg are the decisive legs; F6-F8 prove
the file plane still claims its own shapes bidirectionally.
