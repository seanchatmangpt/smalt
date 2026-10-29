# BK-134r — Internal-Tier Census Reconcile (RELAUNCH of 429-killed BK-134)

**Standing:** **PASS** (census 6/6 green; registry ↔ disk exact; residual internal-tier
failures quantified and attributed — see drift list)
Context: solo
Date: 2026-10-22
HEAD at census runs: `17848b75b4cdc4a85517cc63c575773a02982481` (moved from
session-start `23823584` via coordinator tick checkpoints during this lane;
census re-run and re-green at the moved HEAD).

## Census gate (primary task)

```
$ MIX_BUILD_ROOT=_build-bk134r asdf exec mix test test/internal/internal_tier_census_test.exs
Running ExUnit with seed: 51582, max_cases: 32
......
Finished in 0.1 seconds (0.1s async, 0.00s sync)
Result: 6 passed
```

Ran three times across the session (including re-run after a transient
compile-freeze from another lane's in-flight edit to
`lib/smalt/storage/journal_sink.ex` — resolved by that lane within the
compile-freeze SLA; compile exit 0 at settle, census re-run green). All three
runs: **6/6 passed**.

## Registry ↔ disk sync (step 2/3 of task)

BK-71's census registry already covers the full `test/internal` population —
**no unregistered files remain; no registration work needed**:

```
disk files:      61   (ls test/internal)
registered rows: 61   (@registered in internal_tier_census_test.exs)
comm diff both directions: empty
```

The task premise (az1/az2/az3/az4/webpubsub/bk85/bk101 unregistered) is stale:
az2, az4, bk85, bk101, webpubsub, expl3_dataplane_repairs are all present in
`@registered` with BK-71's class/exemption rows (e.g.
`"az2_maa_attestation_court_test.exs" => :internal` with `[:status_literal]`,
`"az4_mhsm_release_policy_court_test.exs" => :wire` with `[:client_token]`,
`"webpubsub_test.exs" => :wire` with `[:client_token]`). BK-62's 6
CensusTest failures are likewise confirmed gone (BK-71's registry landed).

## Broader internal-tier quantification (step 2)

```
$ MIX_BUILD_ROOT=_build-bk134r asdf exec mix test test/internal
Result: 289/303 passed
Failed: 14 tests
```

(Earlier run on an intermediate lane-edit state: 292/303, 11 failures — the
failure set tracks in-flight uncommitted lane work, not census drift.)

Failures cluster in three files, all attributable to in-flight lanes, none
census-registration related:

| file | failures | disposition |
|---|---|---|
| `test/internal/kafka_wire_test.exs` | 7 | BK-122r kafka probe lane in-flight (uncommitted lib + test edits); not census drift |
| `test/internal/powl2_primitives_test.exs` | 6 | in-flight lane work (MatchError in rule/delivery surface); not census drift |
| `test/internal/spof3_affidavit_engine_court_test.exs` | 1 | `:engine_busy` timeout court — timing-sensitive, observed flaky across runs (passed in the 11-failure run) |

No census test failed. All 6 census sub-gates green on the settled HEAD.

## Drift list + dispositions

1. **Transient compile-freeze** (`lib/smalt/storage/journal_sink.ex`, mid-edit
   by a concurrent lane): resolved by owner lane within SLA; compile exit 0;
   census re-run green. Disposition: no action this lane (disclosure per
   compile-freeze disclosure law — this lane did not modify the file).
2. **Stale task premise** (unregistered AZ/EXPL files): already registered by
   BK-71. Disposition: no registration performed; census green as-is.
3. **Residual internal-tier failures** (14, three files, all non-census):
   owned by BK-122r (kafka), powl2 lane, and a flaky SPOF-3.2 timing court.
   Disposition: left for owner lanes; census population fence is the gate this
   receipt stands behind, and it is green.

## Replay

```
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-bk134r asdf exec mix test test/internal/internal_tier_census_test.exs
MIX_BUILD_ROOT=_build-bk134r asdf exec mix test test/internal
```

Not committed (per lane contract).
