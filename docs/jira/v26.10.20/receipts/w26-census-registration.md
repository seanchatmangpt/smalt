# W26 — Internal-Tier Census Registration

**Standing:** PARTIAL_ALIVE

Date: 2026-10-21 · Lane: W26 (registrar) · Repo: /Users/sac/smalt

## Scope

Registered the wave's new test/internal files in
`test/internal/internal_tier_census_test.exs` (registrar follow-up to W25-B's
drift finding). Only the census file was touched (W26-owned).

## Allowlist diff (test/internal/internal_tier_census_test.exs, +8 lines)

@owned_files += [
  "cosmos_kd65_scripts_test.exs",
  "kd128_partition_readout_test.exs",
  "kd134_requester_delivery_test.exs"
]
# kd115_credit_first_delivery_test.exs was already registered.

@observables += [
  "Smalt.Amqp.FrameCodec",        # kd134
  "Smalt.Amqp.Connection",        # kd134
  "Smalt.Amqp.SasVerifier",       # kd134
  "Smalt.Amqp.ManagementRpc",     # kd128
  "Smalt.Internal.Kd128PartitionReadoutTest"
]
# kd134 module is InternalTier.Kd134RequesterDeliveryTest (not Smalt-prefixed,
# not scanned); kd65 module is DataPlane.CosmosKd65ScriptsTest (likewise not
# scanned). Smalt.Store, Smalt.Amqp.QueueStore, Smalt.Messaging.EventHubs,
# Smalt.DataPlane.Cosmos were already allowlisted.

## Census run (MIX_BUILD_ROOT=_build-w26, mix test test/internal/internal_tier_census_test.exs)

6 tests, 2 failures — population fence PASSES (the new files are counted,
not flagged as drift) and the observables allowlist test PASSES. The 2
failures are forbidden-token scans now correctly reaching the newly
registered files; the violations live in lane-owned files, classified below,
not fixed by W26.

Real output:

  1) test no ARM path literals — 1 violation:
     kd134_requester_delivery_test.exs: "@arm_key \"/subscriptions/sub/.../queues/kd134-q\""

  2) test no HTTP status literal co-occurs with assert — 8 violations:
     cosmos_kd65_scripts_test.exs x6 (assert {:ok, 201/200, ...} lines)
     kd128_partition_readout_test.exs x2 (assert %{status_code: 200, ...})

## Full internal-tier run (mix test test/internal/): 56 tests, 6 failures

Classification (W26 classified, did not fix):

- Census findings 1-2 (above): kd134 file is committed (4b12321/25d5dd0) so
  its ARM-literal violation is a real, standing census finding — the kd134
  lane should build the key from concatenated parts (the census file's own
  client_patterns/1 pattern shows the lawful form) or the census contract
  should grandfather it. kd65/kd128 files are untracked/mid-flight from
  concurrent lanes; their status-literal asserts are the same class.
- Failures 3-6 (cosmos_analytical_ttl_test.exs): pre-existing, NOT session-
  introduced and NOT census — `Smalt.DataPlane.Cosmos.analytical_store_sweep/2`
  and `effective_ttl/2` are undefined or returning nil at runtime; the lib
  cosmos module appears mid-edit by a concurrent lane (compile warning:
  "Smalt.DataPlane.Cosmos.effective_ttl/2 is undefined or private"). Lane W26
  takes no action; the cosmos lane owns this.

## Receipt-integrity notes

Exit code of census run: 2 (2 test failures). Exit code of full tier: 1.
All counts re-read from the actual mix test output in this session, not
recalled. Poll helper untouched; no sleeps introduced.

See Also: docs/jira/v26.10.20/receipts/INDEX.md
