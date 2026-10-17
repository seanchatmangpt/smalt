# i3 — witness receipts over in-flight lib/ (lane I3)

Date: 2026-10-17 14:44–14:50 PDT. Repo: /Users/sac/smalt. Lane: I3 of
docs/jira/v26.10.17/_LANES.md. All runs: `MIX_BUILD_ROOT=_build-lane3`.
lib/ and test/ untouched. Standing: **PASS with 2 witnessed exception clusters**
(deterministic compliance failures — real, stable across reruns; see §4).

## 1. KD-87 — `test/arm/kd87_sts_leading_empty_segment_test.exs`

Shims under witness: `lib/smalt/arm_gateway/router.ex:85-86`,
`lib/smalt/auth/bearer.ex:180`.

Command: `MIX_BUILD_ROOT=_build-lane3 mix test test/arm/kd87_sts_leading_empty_segment_test.exs`

Real output (14:44:16):

```
Running ExUnit with seed: 677580, max_cases: 32
Excluding tags: [:amqp_wire]

14:44:16.780 [info] POST /00000000-0000-0000-0000-000000000000/oauth2/v2.0/token
14:44:16.850 [info] Sent 200 in 70ms
14:44:16.850 [info] POST /oauth2/v2.0/token
14:44:16.851 [info] Sent 200 in 331µs
.
Finished in 0.1 seconds (0.00s async, 0.1s sync)
2 tests, 0 failures
```

Standing: PASS. Exit 0. This receipt's mtime is the kd_flip gate input for KD-87.

## 2. KD-79 / KD-83 — `test/arm/fr5_tf_divergence_closures_test.exs`

Command: `MIX_BUILD_ROOT=_build-lane3 mix test test/arm/fr5_tf_divergence_closures_test.exs`

Real output (14:44:27):

```
Finished in 0.2 seconds (0.00s async, 0.1s sync)
18 tests, 0 failures
```

Standing: PASS, exit 0.

## 3. AMQP wire tier

Command: `MIX_BUILD_ROOT=_build-lane3 mix test test/amqp/connection_test.exs test/amqp/event_hubs_test.exs --include amqp_wire`

- Run 1 (14:44): `49 tests, 1 failure` —
  `test/amqp/event_hubs_test.exs:402` (`sweep` cleared-count assertion,
  `assert is_integer(cleared) and cleared >= 1` after `Process.sleep(10)`
  expiry). Timing-sensitive.
- Run 2, identical command (exit 0):

```
Finished in 1.3 seconds (0.00s async, 1.3s sync)
49 tests, 0 failures
```

- Isolated rerun `mix test test/amqp/event_hubs_test.exs:402 --include amqp_wire`:

```
1 test, 0 failures (33 excluded)
```

Standing: PASS on rerun; the :402 sweep-claim test is timing-sensitive
(1 ms lease + 10 ms sleep) and flaked once in three runs of that surface.

## 4. Sweep — modified/new test files covering changed lib/

16 files, each run solo (`MIX_BUILD_ROOT=_build-lane3 mix test <file>`).
IMPORTANT: when the first 8 files were run as ONE mix invocation they
interfered (321 tests, 71 failures, all 401/MissingBearerToken-class
cross-file shared-state artifacts — e.g. `Kd79BlobApiVersionWireTest`
setup: "parent SA creation failed: 401"). Every one of those files is green
solo. Per-file results are the standing record:

| test file | exit | tests | failures |
|---|---|---|---|
| test/kd79_blob_apiversion_wire_test.exs | 0 | (green) | 0 |
| test/arm_cors_test.exs | 0 | 3 | 0 |
| test/mix_auth_scope_test.exs | 0 | 4 | 0 |
| test/data_plane/vault_data_test.exs | 0 | 2 | 0 |
| test/lro_test.exs | 0 | 33 | 0 |
| test/mcp_test.exs | 0 | 52 | 0 |
| test/data_plane/blob_hardening_test.exs | 0 | 116 | 0 |
| test/egress_dispatch_test.exs | 0 | 107 | 0 |
| test/egress_kv_appconfig_test.exs | 0 | — | 0 |
| test/config_replay_identity_test.exs | 0 | — | 0 |
| test/error_codes_doc_test.exs | 0 | — | 0 |
| test/smalt_egress_router_test.exs | 0 | — | 0 |
| test/wire/egress_wire_test.exs | 0 | — | 0 |
| test/amqp/atom_bridge_test.exs | 0 | — | 0 |
| test/compliance_test.exs | 2 | 157 (16 excl) | **40** |
| test/trust_profile_deployment_test.exs | 0 | — | 0 |

Representative green output (blob_hardening, egress_dispatch, lro, mcp):

```
116 tests, 0 failures    # blob_hardening, exit 0
107 tests, 0 failures    # egress_dispatch, exit 0
33 tests, 0 failures     # lro, exit 0
52 tests, 0 failures     # mcp, exit 0
```

### 4a. DETERMINISTIC compliance failures (stable across 2 reruns)

`test/compliance_test.exs` → exit 2, `157 tests, 40 failures (16 excluded)`,
identical failure distribution both runs:

```
  15 Compliance.C2KeyvaultTest
   6 Smalt.Compliance.C1ArmTest
  19 Smalt.Compliance.C4BlobTest
```

Witnessed failure classes (all against the in-flight lib/ diffs; this lane
does not edit lib/ — flagged for the owning lanes):

- **C2Keyvault (15)**: key create returns `401 AuthenticationFailed
  MissingBearerToken` — e.g.
  `create c2-rsa-15625 returned 401: {"error":{"code":"AuthenticationFailed","message":"MissingBearerToken"}}`
  (test/compliance/c2_keyvault.exs:195 → :249). Auth-surface drift against
  the bearer.ex / router.ex shims in flight.
- **C1Arm (6)**: api-version error envelope shape drifted — e.g. expected
  `InvalidApiVersionParameter`, got `InvalidResourceShape`
  (test/compliance/c1_arm.exs:254-262).
- **C4Blob (19)**: x-ms-version error message no longer matches the
  compliance copy ("Missing required x-ms-version header, SAS token, or
  allowlisted host." vs expected "x-ms-version header is required for blob
  storage routes."), conditional/ranged HEAD returns 200 where 412/206 are
  asserted (c4_blob.exs:1126, :1068), and a FunctionClauseError in
  `Kernel.=~/2` on a header value (c4_blob.exs:1002).

## 5. kd_flip inputs

- KD-87: this receipt postdates the shim lines' current mtime; run of
  `scripts/kd_flip.py --apply` left to the kd-registrar (read-only for this
  lane).

## 6. Falsifiers / caveats

- Batched (multi-file) mix invocations are NOT valid witnesses for these
  surfaces — cross-file 401 interference reproduces at will. Witness per file.
- compliance_test.exs failures are real and deterministic; whoever owns
  c1_arm/c2_keyvault/c4_blob compliance rows must reconcile lib/ against the
  expected envelopes before court-x2, or register as KD rows.
