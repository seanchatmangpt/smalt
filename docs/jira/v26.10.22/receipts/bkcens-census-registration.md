# BK-CENS — internal-tier census registration reconcile

- **Date**: 2026-10-22
- **Lane**: BK-CENS
- **Standing**: ALIVE
- **Context**: solo

## Scope

Landed-but-unregistered `test/internal` court files tripped the population
fence. All three named files exist on disk with landed receipts:

| file | class | receipt |
|---|---|---|
| `kd173r_audience_scope_court_test.exs` | :internal + `[:status_literal]` exemption | `kd173r-audience-repair.md` (ALIVE) |
| `bkamqpf_f2a_boundary_court_test.exs` | :wire | `bkamqpf-f2a-boundary.md` (CLOSED-BY-UPSTREAM-REPAIR, court retained) |
| `eplaw_ephemeral_boot_court_test.exs` | :internal | `expl6r1-journal-repairs.md` (ALIVE) |

No ghost registrations; nothing left SKIP — all three lanes landed.

## Changes

1. `test/internal/internal_tier_census_test.exs` — 3 registration rows,
   1 typed exemption (`kd173r`: in-process SasVerifier court on typed
   `{:error, {401, _}}` refusal tuples), 4 observables allowlist entries
   (`Smalt.Amqp10.Connection`, the two new self-module refs,
   `Smalt.EplawEphemeralBootCourtTest`).
2. `test/internal/eplaw_ephemeral_boot_court_test.exs` — minimal unblock
   (compile-freeze SLA disclosure, BK-CENS lane): two `# SLEEP-CLASS:
   POLL-STEP` annotations on already-deadline-checked bounded-poll sleeps
   (child-eval settle after `System.stop(0)`; `do_poll/2` connect-probe
   loop). Comment-only, no behavior change; owned by the EXPL6-R1 lane.

## Before census (4 failures)

```
Result: 2/6 passed
Failed: 4 tests
  1) population fence ... on_disk=MapSet.new(["bkamqpf_f2a_boundary_court_test.exs",
     "eplaw_ephemeral_boot_court_test.exs", "kd173r_audience_scope_court_test.exs"]) unregistered=MapSet.new([])
  2) off-allowlist module references: [{bkamqpf, Smalt.Internal.BkamqpfF2aBoundaryCourtTest},
     {bkamqpf, Smalt.Amqp10.Connection}, {eplaw, Smalt.EplawEphemeralBootCourtTest},
     {kd173r, Smalt.Internal.KD173RAudienceScopeCourtTest}]
  3) status-literal asserts: [{kd173r, assert {:error, {401, "INVALID_LOCAL_SAS"}} ...} x2]
  4) unaudited pacing: [{eplaw, Process.sleep(250)}, {eplaw, Process.sleep(100)}]
```

## After census

```
$ MIX_BUILD_ROOT=_build-bkcens mix test test/internal/internal_tier_census_test.exs
......
Finished in 0.1 seconds (0.1s async, 0.00s sync)

Result: 6 passed
```

## Newly-registered files run green (real output)

```
$ MIX_BUILD_ROOT=_build-bkcens mix test test/internal/kd173r_audience_scope_court_test.exs \
    test/internal/bkamqpf_f2a_boundary_court_test.exs
Finished in 55.5 seconds (0.00s async, 55.5s sync)
Result: 7 passed

$ MIX_BUILD_ROOT=_build-bkcens mix test test/internal/eplaw_ephemeral_boot_court_test.exs
Finished in 9.3 seconds (0.00s async, 9.3s sync)
Result: 3 passed
```

## Non-vacuity note

One intermediate self-trip: the census's own honest-self-scan caught my
first exemption comment containing "assert" + "401" on one line
(`status-literal asserts: [{"internal_tier_census_test.exs", ...}]`) — the
gate refused its own author's comment, confirming the scan is live.
