# EXPL9-R2 — ARM gateway guards: F1 oversized-body 413 + F3 create-location 400

**Standing:** ALIVE
Context: solo
Date: 2026-10-22
Lane: EXPL9-R2 (owns `lib/smalt/arm_gateway/router.ex` + court test)

## Repairs (from docs/jira/v26.10.22/receipts/expl9-egress-arm-errc.md)

### F1 (HIGH) — `sb_atom_alias` unguarded read_body → lying 500 on >8MB body

`lib/smalt/arm_gateway/router.ex` (`sb_atom_alias/3`, was line 7013): the
unguarded `{:ok, body, conn} = Plug.Conn.read_body(conn)` was replaced with a
guarded `case` mirroring the canonical shape at `egress_router.ex`
`blob_block_arm`:

- `{:more, partial, _conn}` → **413** `RequestBodyTooLarge` ARM envelope
  (byte cap 8,000,000, `read_length: 1_000_000`, `error.target` = path)
- `{:error, reason}` → **400** `InvalidRequestBody` ARM envelope
- `{:ok, body, conn}` → unchanged dispatch via new `sb_atom_alias_dispatch/4`
  (path reconstruction + AtomBridge dispatch byte-identical)

Carrier: `# KD-COVERS: KD-174` comment at the gate; KD-174 row mint/close is
kd-registrar's (coordinator routes).

### F3 (MED) — `do_rg_put` create-without-location succeeded 201 with default

`do_rg_put/3` restructured to read the existing record once, then `cond`:

- CREATE (no existing record) with no `location` key in the body → **400**
  `LocationRequired` ARM envelope, target = rg id
- UPDATE with changed location → unchanged **400** `LocationMismatch` (R30
  guard preserved; same read, same message, same default
  `Map.get(payload, "location", "eastus")` so a defaulted update PUT against
  an eastus group still succeeds 200)
- otherwise → `build_and_put_rg/4` unchanged (201 create / 200 update)

## Court (test/internal/expl9r2_arm_guard_court_test.exs) — real HTTP, real 9MB body

Real HTTP/1.1 (:httpc) against the real ArmGateway.Router listener (app
self-boots on ephemeral ports under mix test), real Smalt.Store, no mocks, no
sleeps. 8 tests:

```
$ MIX_BUILD_ROOT=_build-expl9r2 mix test test/internal/expl9r2_arm_guard_court_test.exs
...
05:10:55.305 info[] PUT /q-expl9r2-bigbody-259
05:10:55.309 info[] Sent 413 in 3ms
.
Finished in 0.1 seconds (0.00s async, 0.1s sync)

Result: 8 passed
```

Falsifiers exercised:

- 9MB `application/xml` PUT `/:entity_name` → **413** with
  `error.code == "RequestBodyTooLarge"` and `error.target == "/<entity>"`
  (flips the witnessed 500; first run of the lane confirmed the flip by
  failing 3/8 against the pre-fix helper path before the test-helper content
  type was corrected — the 413 itself was green from the first run)
- small `QueueDescription` XML → **201** with parsed `MaxDeliveryCount`
  (baseline unchanged)
- `{}` RG create → **400** `LocationRequired`; bodyless RG create → **400**
  `LocationRequired`; located create → **201** `westus2` (baseline unchanged)
- R30: mismatched-location update → **400** `LocationMismatch`; update
  WITHOUT a location field against an eastus group → **200** (defaulted
  update tolerated, guard not over-tightened)
- The read_body `{:error,_}` arm has no cheap real-transport witness; it is
  pinned by a source-level fence in the court (guard arms present) and is
  the same shape as the canonical `blob_block_arm` 400 arm.

## Regression

```
$ MIX_BUILD_ROOT=_build-expl9r2 mix test test/internal/rg404_concurrent_lifecycle_court.exs test/internal/bk14_kd143_sqlfilter_persistence_test.exs test/internal/eh_arm_test.exs
...
Result: 15 passed
```

Compile: `MIX_BUILD_ROOT=_build-expl9r2 mix compile` — 0 errors.

## Compile-freeze disclosure

`lib/smalt/attestation/maa.ex` (EXPL9-R1 lane's in-flight file) did not
compile at lane start (`reserved` bound in a with clause, read in else —
undefined variable at line 191). Before this lane applied any fix, the owning
lane landed its own unblock (hoisted `decode_runtime` + else-branch derivation
of the reserved nonce, comment "KD-169R compile-freeze unblock (disclosed)").
This lane applied NO edit to maa.ex; disclosure here completes the
cross-lane receipt per the SLA (the freeze was on the shared compile, cleared
by the owner within the window).

## Files (this lane's staged set)

- `lib/smalt/arm_gateway/router.ex`
- `test/internal/expl9r2_arm_guard_court_test.exs`
- `docs/jira/v26.10.22/receipts/expl9r2-arm-guards.md`
