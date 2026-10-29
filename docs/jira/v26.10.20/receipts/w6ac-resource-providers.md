# w6ac — ARM resource-provider faces (list / register / unregister)

**Standing:** **ALIVE** (module-direct witness all-green, real output below;
wire tier rides the staged router patch, applied post-split at w6R
integration)

Lane: wave-6 `w6ac`, 2026-10-20. Exclusive surface:
`lib/smalt/arm/resource_providers.ex` (NEW). ROUTER HOLD respected — no
edits to `lib/smalt/egress_router.ex` / `arm_gateway/router.ex`; the wire
patch is staged at `tmp/w6ac_router_patch.md` (~15 lines: 3 routes, no
helper needed — each route is a 1-line call + case).

## What landed

`Smalt.Arm.ResourceProviders` — every namespace smalt's ARM actually serves,
seeded from `Smalt.Registry.admitted_resource_types/0` (19 namespaces / 49
admitted types, no invented namespaces), renders as a provider record:

- `providers/0` / `provider/1` — reads apply (and persist) the read-triggered
  transition.
- `register/1`/`unregister/1` → transitional state now (`Registering`/
  `Unregistering`), terminal state on next read — immediate-transition
  emulation of real ARM's async RP registration (no timers, no sleeps).
- Public wire helpers `provider_wire/1` / `providers_wire/0` +
  `invalid_namespace_error/1` (typed 400 `InvalidResourceNamespace`).
- Table `:smalt_arm_providers`, `:heir` 3-tuple to init.

## Verification

Standalone compile clean (only expected `Smalt.Registry` availability
warnings under standalone elixirc; zero errors, beam in `/tmp/w6ac_ebin`).
Full-tree `mix compile --warnings-as-errors` was compile-frozen by the w6R
router restructure mid-write (`lib/smalt/egress/AppConfig.ex` SyntaxError at
the time of this lane's full-tree attempt); per SLA the lane verifies
standalone and the witness ran over real module code + real Registry seed —
no mocks, no sleeps.

## Witness (real output, captured to tmp/w6ac_witness.log)

```
SEED_PROVIDERS=19
ADMITTED_NS_COUNT=19
SEED_COMPLETE=true
STORAGE_STATE=registered
REGISTER_TRANSITIONAL=registering
AFTER_READ=registered
UNREG_TRANSITIONAL=unregistering
UNREG_TERMINAL=unregistered
REREGISTER_TRANSITIONAL=registering
REREGISTER_TERMINAL=registered
WIRE_VALUE_COUNT=19
WIRE_RT=%{"apiVersions" => ["2023-05-01"], "resourceType" => "storageAccounts"}
WIRE_STATE=Registered
UNKNOWN_TYPED={:error, :invalid_namespace}
ERR_CODE=InvalidResourceNamespace
W6AC WITNESS: ALL FACES OK
```

(Definitive run log: `tmp/w6ac_witness.log`. Replay: `elixir -pa /tmp/w6ac_ebin --eval 'Code.require_file("tmp/w6ac_witness.exs")'`.)

## Falsifier for integration

Re-run the witness on the integrated tree — green under a neutered seed
(witness must go RED if `ensure_seeded` skips namespaces) is the
non-vacuity contract for this face.

## RE-WITNESS addendum — 2026-10-22 (lane BK-REWIT3): cheap replay PASS — ALIVE

Re-ran `tmp/w6ac_witness.exs` on `_build-rewit3` (`mix run --no-start`):
`SEED_PROVIDERS=19 / ADMITTED_NS_COUNT=19 / SEED_COMPLETE=true /
STORAGE_STATE=registered / REGISTER_TRANSITIONAL=registering /
AFTER_READ=registered / UNREG…unregistered / REREGISTER…registered /
WIRE_VALUE_COUNT=19 / WIRE_RT / WIRE_STATE=Registered /
UNKNOWN_TYPED={:error, :invalid_namespace} / ERR_CODE=InvalidResourceNamespace
/ W6AC WITNESS: ALL FACES OK`, exit=0 — 1:1 with the original witness.
SUSPECT cleared; ALIVE on the integrated tree.
