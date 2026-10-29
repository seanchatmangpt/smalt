# w6bh — ARM quota/usage faces (v26.10.20)

**Standing:** ALIVE (module tier). No mocks, no Process.sleep.
Wire mount is a ~3-line staged router patch (ROUTER HOLD respected; noted in the moduledoc).

## Landed
`lib/smalt/arm/quota_usage.ex` (NEW): per-location usage rollups for the
8 registry-admitted families (Compute/Network/Storage) computed from the
REAL `:smalt_resources` store. Limits are documented Azure published
defaults (see moduledoc). Unknown location → `{:error, :unknown_location}`
(wire 400 InvalidLocation); unknown namespace → `{:error, :unknown_namespace}`.

## Witness (real, exit 0) — verbatim from tmp/w6bh_witness.out
F1_VM_COUNT=true
F2_VM_LIMIT_FLOOR=true
F3_LOCATION_ISOLATION=true
F4_NIC_COUNT=true
F5_SA_COUNT=true
F6_NAME_SHAPE=true
F7_UNKNOWN_LOCATION_REFUSED=ok
F8_UNKNOWN_NS_REFUSED=ok
F9_FAMILY_COUNT=true
W6BH WITNESS: ALL FACES OK

## Replay + falsifier
Replay: `MIX_BUILD_ROOT=_build-lane-w6bh MIX_ENV=test mix run --no-start tmp/w6bh_witness.exs` → exit 0.
Falsifier: green requires exact counts (VM 2 vs 1 across locations), the
limit floor, name-shape exactness, and the F7/F8 typed refusals — green
under a broken rollup would be vacuous.
