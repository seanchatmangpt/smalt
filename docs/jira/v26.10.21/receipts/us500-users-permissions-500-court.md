# USERS500 — Cosmos users/permissions empty-body 500: closed STALE-BEAM + healthy-shape court

**Standing:** **PARTIAL_ALIVE** — surface healthy (wire 201 witnessed on the current shared beam), court landed green; one landed compile-freeze repaired (disclosed); AMQP integration courts red pre-existing, out of lane scope.

Context: solo

## Verdict

POST /dbs/{db}/users[/permissions] does **NOT reproduce** on the current shared beam (pid 85369, OTP-29, never restarted by this lane). Verdict: **stale-beam artifact**. The 500-era surface is fenced by a new Chicago court.

## Wire evidence (shared beam, in place)

STS token via `POST http://127.0.0.1:9443/common/oauth2/v2.0/token` (client u500), probes on the data plane `127.0.0.1:8443`:

- `POST /dbs/u500db/users` `{"id":"u500user"}` → **201**, full Azure record:
  `{"_etag":"\"fe8031d805bd6c13\"","_rid":"PhU7Jmdme2cG-mU_vtNMNQ","_self":"dbs/u500db/users/u500user/","_ts":1792617851,"id":"u500user","permissions":"dbs/u500db/u500user/"}`
- `POST /dbs/u500db/users/u500user/permissions` `{"id":"perm1","permissionMode":"Read","resource":"dbs/u500db/colls/c1"}` → **201** with `_self .../permissions/perm1/`, `permissionMode`, `resource`
- typed errors: missing `resource` → 400 `BadRequest` "Required property 'resource' is missing"; `permissionMode:Bogus` → 400 "permissionMode must be Read or All"; unknown user → 404 `NotFound` "Entity with id nosuchuser not found"

Probes hit 9443/9444 first: 404 RouteNotFound (the users surface lives on the data-plane egress pipeline, port 8443) and 401 before the STS token; the substrate processes were never touched by this lane.

## Court

`/Users/sac/smalt/test/data_plane/cosmos_users_permissions_court.exs` (new, untracked — lane does not commit; coordinator commits per-lane). Chicago: real `Smalt.CosmosAuthzPlug` dispatch over the real `CosmosAuthz` ETS store, no mocks, final-state asserts:

- create-user 201 with `_etag/_rid/_self/_ts/id`; duplicate → 409 `UserConflict`; feed 200 `_count>=1`
- create-permission 201 Read + All; missing `permissionMode` defaults to "All" by design (`lib/smalt/data_plane/cosmos_authz.ex`); missing `resource` → 400; bad mode → 400
- 405 on PUT user item

Court result (cosmos tier, `MIX_BUILD_ROOT=_build-u500`, Elixir 1.20.4-otp-29):

```
Finished in 1.3 seconds (0.00s async, 1.2s sync)
Result: 64 passed
```

## Compile-freeze repair (disclosed)

HEAD (a448c8c, "landed closer deltas", committed 14:25:49) landed a mangled 91-line `lib/smalt/messaging/amqp10/frame_decoder.ex` — TokenMissingError, blocks ALL compilation, so the tier baseline was compile-broken, not red. After the file's mtime stalled >10 min and `git show a448c8c:...` confirmed the corruption is committed (not an in-flight lane edit), this lane restored the last-known-good 359-line parent version (`a448c8c^`, sha 5d9f4ce4b6ab62c905d36c43e852caa2fcc5f1bb). The broken committed copy is preserved at `/tmp/frame_decoder.inflight.u500.ex` (sha 4142bf76b6425ff5243e4d5187559da69385a9d5).

Tier result after repair: cosmos tier 64/64 green; **AMQP10 integration courts 4/14** (debug/skeptic/crash-only; recv-timeout during handshake + a broken test-helper `grab/4` in `test/integration/amqp10_debug_test.exs`) — reproduced identically with parent `queue_storage.ex`, so **pre-existing on this tree, not session-introduced by the decoder restore**. Out of USERS500 scope; flagged for the AMQP owner.

## Falsifier

Re-run the court: `MIX_BUILD_ROOT=_build-u500 mix test test/data_plane/cosmos_users_permissions_court.exs` — a regression of the users/permissions surface flips an assert and exits 1.