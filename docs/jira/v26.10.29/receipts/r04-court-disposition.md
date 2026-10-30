# Receipt r04 — full-suite + court disposition (v26.10.29, ash wave close)

Standing: **ALIVE for the ash wave's own surfaces**; court ladder BLOCKED on
the concurrent lane's in-flight work (recorded, not absorbed).

## Full offline suite (this session, HEAD = ash-wave commits)
    mix test   # 1268/1412 passed, 5 invalid, 8 skipped, 12 excluded
               # 144 failures across 132 files

## Classification
- ZERO failures in ash-wave surfaces: no test from
  test/smalt_ash_gen_test.exs, test/smalt_canonical_router_court_test.exs,
  test/smalt_gen_ash_replay_identity_test.exs failed; no failure file
  touches lib/smalt/ash_gen/, lib/smalt/network*, or arm_gateway mount.
- All 144 failures cluster in the OTHER lane's in-flight surfaces
  (top: bkegs1_fence_court 60, servicebus_rest_dataplane 25,
  marketplace_saas 25, kv_ec_create 20, apim_wire 20, graphlaw_ex_gate_court
  11), with lib/smalt/graphlaw_ex/admission_gate.ex + test/integration/
  namespace_put_test.exs UNCOMMITTED at run time — their wave was mid-flight
  during the court. Consistency witness: court run 1 = 1264/1412, rerun =
  1268/1412 (their state moved between runs).

## Court ladder disposition
    just doctor    # PASS
    just court     # FAILS at test-offline tier (the 144 above)
The gate is red for reasons outside the ash wave; per the law the failures
are recorded with their file classification, never silently absorbed, and
the owning wave gets them.

## Publish-dry (r03 stands)
gate 4 PASS (in-lane fix); gate 1 = GL28-2 window regression
(28f9dcbe postdates release 64dd24cb) — owner decision receipted in r03.

## Wave close state
Commits: a95b6f40, a57ea921, 69c1db49, eddad94f, ea8e346a, b37a1a7e,
c8e8b531 (+ this receipt). Surfaces: generator suite 5/5, router court 4/4,
replay fence 1/1 (flippable, witnessed), existing ARM corpus 19/19,
full-suite zero failures in ash-wave files.
