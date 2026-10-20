# w3e — KV purge bare-DELETE route on the TLS twin (TS wf6 finding)

- **Lane**: w3e (ERRC wave-3)
- **Standing**: PASS
- **Context**: pair (concurrent wave-3 lanes on the shared tree; two compile-freeze
  windows observed and disclosed below)
- **Date**: 2026-10-20

## Finding

TS wf6: `DELETE /deletedkeys/{name}` — the real Azure
`KeyClient.purgeDeletedKey` wire shape — was unrouted on the TLS twin. The
`/deletedkeys` prefix already dispatched to EgressRouter (in
`TlsTwinDispatch.@egress_prefixes`), so this was a route-shape mismatch, not a
dispatch mismatch: only `POST /deletedkeys/:name/purge` existed. The bare
DELETE fell to the blob guarded catch-all and answered `400 MissingXMsVersion`.

## Fix

`lib/smalt/egress_router.ex` (route seam; application.ex verified unchanged —
dispatch prefixes were already correct):

```elixir
  # Real Azure Key Vault purge shape (TS wf6 finding): KeyClient.purgeDeletedKey
  # sends bare `DELETE /deletedkeys/{name}` (204), NOT `POST .../purge`. The
  # POST shape was unrouted on the twin and fell through to the blob guarded
  # catch-all (`/{account}/{container}`), answering 400 MissingXMsVersion.
  delete "/deletedkeys/:name" -> purge_deleted_key(name)   # 204 / 409 / 404
```

Disclosure: `lib/smalt/egress_router.ex` was wave-2 w2f's exclusive file; this
window's wave-3 lanes were also editing it concurrently (my hunk is the
`delete "/deletedkeys/:name"` route at line 1075 only — the diff total on the
file includes other lanes' hunks, not mine).

## Compile

```
$ MIX_BUILD_ROOT=_build-lane-w3e mix compile   (after a sibling blob_storage.ex
in-flight break resolved by its owner per the compile-freeze SLA; two retries
45s + 120s, then EXIT=0)
```

## Witness — live b2 twin (private lane instance, ports 39020-39025, enforce mode)

Real STS token from the twin issuer, curl over https with `--cacert
.smalt/tls/ca-cert.pem`:

```
--- create (POST /keys/:name/create)          200
--- delete key                                 200
--- get deleted (expect 200)                   200
--- PURGE bare DELETE /deletedkeys/:name       204
--- post-purge get                             {"error":{"code":"KeyNotFound"}} HTTP 404
```

(Pre-fix the purge leg answered the blob catch-all `400 MissingXMsVersion`;
this was also reproduced tokenless pre-fix against the shared substrate —
401 challenge shape intact.)

## Test receipt

New: `test/integration/deletedkeys_purge_route_test.exs` — real HTTPS through
the self-booted TLS twin listener (ephemeral port), curl subprocess with
`--cacert` pinned to the listener's real dev cert, auth-disjunctive
(tokenless probe → anonymous passes / enforce → real STS dance, resilient to a
concurrent async test flipping global `:auth_mode`). Chicago: real transport,
final wire state asserted (delete 200 → purge 204 → post-purge 404
KeyNotFound). Placed in `test/integration/` beside the KD-104 witness: the
internal tier's census fences (population fence, status-literal assert ban,
observables allowlist) forbid HTTP-driving suites there — extending those
fences is a reviewed-diff decision I did not make unilaterally.

```
$ MIX_BUILD_ROOT=_build-lane-w3e mix test test/integration/deletedkeys_purge_route_test.exs
1 test, 0 failures   (x3 consecutive runs)

$ MIX_BUILD_ROOT=_build-lane-w3e mix test test/integration
20 tests, 0 failures

$ MIX_BUILD_ROOT=_build-lane-w3e mix test test/internal
42 tests, 2 failures — BOTH from eh_geo_dr_test.exs (another lane's in-flight
census extension: status-literal asserts + ARM path literals). Pre-existing to
my diff; my files contribute zero internal-tier violations (file moved out of
test/internal).
```

## Follow-ups for the coordinator

- `just test-budget`: this suite adds one new unbudgeted test — seed via
  `just test-budget-seed` at wrap.
- Sibling eh_geo_dr lane owns the internal census fence extension.
- `MIX_BUILD_ROOT=_build-lane-w3e` is a lane lease (~698 MB) — delete at
  integration per the cleanup law.
- Private b2 substrate (ports 39020-39025) torn down; ports confirmed free.
