# w2f — KD-108 remainder: container ACL wire persistence + blob snapshot lease wire arm

Standing: ALIVE (wire-witnessed on lane b5, 39050-39055)

## Scope

Exclusive file: `lib/smalt/egress_router.ex` (ACL/lease wiring only).
Disclosed SLA unblock (NOT my lane file): `lib/smalt/data_plane/sentinel.ex`
docstring interpolated `dcr` at compile time, freezing all lane builds;
escaped the interpolation (`\#{dcr}`) so the shared tree compiled. The file
has since gained 143 lines from its owner (retention sweep work) — my one-line
escape is inside that diff, disclose to that lane's integration.

## Root cause (ACL wire loss, blob lane c10 finding)

The container ACL PUT arm called `Plug.Conn.read_body/1` on a body that
Plug.Parsers had already consumed. `raw_blob_put?/1` exempts only PUTs with
no `comp` param, so `PUT ?restype=container&comp=acl` was parsed: any
urlencoded/json Content-Type (curl's `--data-binary` default is
`x-www-form-urlencoded`) makes the `:urlencoded` parser eat the
SignedIdentifiers XML; the arm's `read_body` then returns `""`, and
`parse_signed_identifiers("") == {:ok, []}` — a silent 204 ACL CLEAR. This is
why the engine tier passed while the wire lost identifiers: the engine path
never touches the parsers.

## Fix (all in egress_router.ex)

1. `raw_blob_put?/1` new clause: container PUT (2-segment, non-reserved first
   segment) with `comp == "acl"` is parser-exempt — raw stream preserved.
2. ACL arm reads via new `acl_body/1`: `conn.private[:smalt_raw_body]`
   (BodyCache seam) first, stream fallback; read errors are a typed 400
   InvalidRequestBody, never a silent clear.
3. Blob PUT arm: `PUT ?comp=lease&sharesnapshot=<ts>` routed BEFORE the
   fail-closed comp registration to `BlobStorage.lease_blob_snapshot/6`.
   `comp=lease` WITHOUT `sharesnapshot` stays default-deny 400 (GAP surface
   unchanged; flips are receipt-gated via kd_flip.py, coordinator-owned).

## Witness (real output, lane b5 private ports, MIX_ENV=test)

    create:201
    put_acl (curl default urlencoded CT): 204
    get_acl: 200
    BYTE-COMPARE (Id/Start/Expiry/Permission vs request XML): PASS
    put_blob:201  snapshot=2026-10-20T08:53:05.837903Z
    acquire:201  acquire_conflict:409  renew:200  break:202  release:200
    comp=lease without sharesnapshot (default-deny kept): 400

Engine-tier cross-check (mix run, same build):

    parsed n=2
    set: 204
    get: {:ok, [%{"expiry" => "2027-01-01T00:00:00Z", "id" => "id-one",
      "permissions" => "racwdl", "start" => "2026-01-01T00:00:00Z"},
      %{"expiry" => nil, "id" => "id-two", "permissions" => "r", "start" => nil}]}

Internal tier: `MIX_BUILD_ROOT=_build-lane-w2f mix test` →
`89 tests, 0 failures`. (An earlier run showed 5 CensusTest failures from
lane w2j's in-flight `arm_consumer_group_bridge_test.exs` sitting in
test/internal; the owner moved the file and the suite went green — not
session-introduced by w2f.)

## Notes for integration

- Compile: clean (0 errors, lane build `_build-lane-w2f`).
- Foreign hunk observed in egress_router.ex (not mine): a
  `post "/keys/:name/rotate"` route + `kv_respond` reorder at ~line 796,
  from another lane's KeyVault work. Left untouched.
- Snapshot-lease KD/GAP flips are receipt-gated (kd_flip.py) — coordinator
  owns them; this receipt is the witness for the wire arm.
