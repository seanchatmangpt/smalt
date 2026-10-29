# w6ad — Azure Activity Log face (module level)

**Standing:** ALIVE (flipped 2026-10-20 — falsifier green on the post-w6R split tree)
Subject: /Users/sac/smalt @ uncommitted wave-6 tree
Date: 2026-10-20

## What landed
- NEW `lib/smalt/monitor/activity_log.ex` — Activity Log face over smalt's REAL
  telemetry stream. Attaches to the six events that exist in lib/ today
  (admit/refuse, egress refused, cosmos analytical_sweep, event_grid dead_lettered,
  sentinel retention_sweep) plus the contracted ARM-mutation events
  `[:smalt, :arm, :resource, :write|:delete]`
  (`%{resource_id, resource_provider, resource_type, caller, status}`) whose
  emitters ride the staged router patch (ROUTER HOLD — see below). Every observed
  name either exists in lib/ today or is the documented contract; nothing invented.
- Records land in the `:smalt_activity_log` ETS ring: ordered_set, 5k cap,
  `{:heir, Process.whereis(:init), []}` (3-tuple, shadow-table law).
- Query API: `list/1` (timeRange/resourceId substring/operationName exact,
  most-recent-first), `count/0`, `activity_log_result/1` Azure wire shape
  (eventTimestamp ISO-8601, operationName with ns-derived prefix law).
- `execute_event/3` public so the witness drives the REAL `:telemetry` dispatcher.

## Verification (real output, replayable)
Standalone compile (tree compile-frozen by sibling in-flight files incl. the w6R
router restructure — per contract, verified standalone):
    ERL_LIBS=$PWD/_build-lane-w6ad/test/lib elixirc -o tmp/w6ad/ebin lib/smalt/monitor/activity_log.ex
    # rc=0 (exit 0), beam emitted, zero errors

Witness (real :telemetry dispatcher, no mocks, no sleeps):
    cd tmp/w6ad && ERL_LIBS=... elixir -pa ebin -e '... Code.require_file("tmp/w6ad_witness.exs")'
    COUNT_ALL=7
    ARM_WRITE_HITS=1          # op = Microsoft.Authorization/policyDefinitions/write
    ARM_DELETE_HITS=1
    RID_FILTER_HITS=2 / RID_FILTER_MISS=0   # filter exactness
    RECENT_FIRST=true
    WIRE_OP=Microsoft.Authorization/policyDefinitions/write
    WIRE_TS_ISO=true
    RING_SIZE=5000            # exactly at cap
    CAP_OK=true               # 5001st write evicted oldest via real dispatcher
    W6AD WITNESS: ALL LEGS DONE

One defect found+fixed during witness: activity_log_result double-prefixed ARM
ops ("Microsoft.Smalt/Microsoft.Authorization/...") — fallthrough now only
prefixes "smalt."-derived names.

## Typed deferral (NOT hand-waved)
- Full-tree `mix compile --warnings-as-errors` could not reach a green window
  (sibling in-flight files incl. w6R's router restructure); verified standalone
  (rc=0 beam) + syntax-checked + witnessed standalone. Full-tier flip to ALIVE
  rides the post-split integration window.
- ARM emitters not yet in the router (ROUTER HOLD): the two contracted events are
  witnessed through the real dispatcher; the wire patch is staged in the
  moduledoc. Post-split, the router lane adds the execute sites; this module
  observes them with zero further changes.
- Internal-tier census not updated (module has no test file; witness is the tier
  for this surface at integration, per w6s/w6l precedent).

## Falsifier (integration)
Re-run tmp/w6ad_witness.exs on the green tree; a green run under a broken filter
or non-capping ring would be vacuous.

## Cleanup
- `_build-lane-w6ad` lease left for coordinator `just lane-clean` at integration.
- tmp/ scratch (w6ad/ebin, w6ad_witness.exs) kept for replay.

## ALIVE flip (integration window, 2026-10-20)
Staged falsifier re-run on the post-w6R split tree (`MIX_BUILD_ROOT=_build-lane-w6ad MIX_ENV=test mix run --no-start tmp/w6ad_witness.exs`, real dispatcher):
    COUNT_ALL=7
    ARM_WRITE_HITS=1   (Microsoft.Authorization/policyDefinitions/write)
    ARM_DELETE_HITS=1
    RID_FILTER_HITS=2 / RID_FILTER_MISS=0
    RECENT_FIRST=true
    WIRE_OP=Microsoft.Authorization/policyDefinitions/write
    RING_SIZE=5000, CAP_OK=true
    W6AD WITNESS: ALL LEGS DONE
Witness fix: `Application.ensure_all_started(:telemetry)` prepended (mix run --no-start does not start apps; the original standalone run started telemetry explicitly).
Full-tree compile green (deadlock resolved by w6R; green at poll 9 of the bounded probe).

## Router-patch draft disposition (disclosed, NOT applied)
Placement checked: ARM routes remain in `lib/smalt/arm_gateway/router.ex` (the w6R delegators cover kv/cosmos/appconfig/attest/observability planes; ARM did not move). There is NO central mutation funnel in the ARM router (`send_arm_error/6` is errors-only), so the `:telemetry.execute([:smalt, :arm, :resource, :write|:delete])` patch is NOT a small additive edit — it is one call per mutating route family across the 6k-line router. Per the coordinator's only-if-small condition, NOT applied. Follow-up lane: add emitters per mutating ARM route family post-integration; this module observes them with zero further changes.
