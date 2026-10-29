# w6i — ARM deployments faces (re-dispatch w6i-2)

**Standing:** PARTIAL_ALIVE

## Landed

- lib/smalt/arm/deployments.ex (NEW): PUT/GET/LIST/DELETE deployments at both
  scopes ({sub, rg} and {sub, nil}); POST validate face with InvalidTemplate +
  details array (missing/non-object template, non-list resources, unknown mode);
  shadow ETS :smalt_arm_deployments + :smalt_arm_deployments_ops, both :heir
  3-tuple to init; provisioningState Succeeded on admission; deploymentOperations
  echo face (one Create op per PUT).
- lib/smalt/arm_gateway/router.ex (additive, before catch-all): deployment routes
  at both scopes + validate + operations child routes; handlers
  deployments_put/get/list/delete/validate/ops/body; catch-all `match _` intact.
- Compile gate: MIX_BUILD_ROOT=_build-lane-w6i-2 mix compile GREEN on the shared
  tree (multiple green polls; zero deployments-related warnings).

## Witness

Module-direct, 13/13 PASS (real output):

    PUT_OK provisioningState=Succeeded
    GET_ECHO_OK name=dep-good mode=Incremental
    LIST_OK count=1
    VALIDATE_OK passed
    VALIDATE_NO_TEMPLATE_400 code=InvalidTemplate details=1
    VALIDATE_BAD_RESOURCES_400 code=InvalidTemplate
    VALIDATE_BAD_MODE_400 code=InvalidTemplate
    OPS_OK count=1 state=Succeeded
    GET_404_OK
    DELETE_OK
    DELETE_CONFIRMED_404
    SUB_SCOPE_OK count=1
    W6I2-WITNESS-PASS

Replay:

    elixir -pa _build-lane-w6i-2/dev/lib/jason/ebin -pa tmp/w6i2_ebin tmp/w6i2_witness.exs

Wire tier: typed-BLOCKED — lane substrate boots fail on sibling lanes' rolling
in-flight compile breaks (dns.ex / egress_router implementation-limit windows);
witness script staged at tmp/w6i2_witness.exs for wire replay after integration.

## Disclosures

- Prior lane w6i was BLOCKED on generation corruption and landed nothing; this
  re-dispatch (w6i-2) hit the same corruption class twice mid-lane (a corrupted
  module draft and a corrupted routes Edit — the corrupting Edit calls were
  rejected/repaired immediately, verified on disk, and the shared tree was left
  clean). Both corruptions were detected by grep for placeholder-token patterns +
  compile, before landing.
- No git commands. No mocks, no Process.sleep.
- Build root _build-lane-w6i-2 left for coordinator lane-clean at integration.
- Out-of-scope note: sibling lanes were rolling broken during this lane
  (dns.ex, cosmos.ex, egress_router.ex implementation-limit windows); none
  repaired by me.
