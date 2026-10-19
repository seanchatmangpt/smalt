# i29 — EventGrid :334 + GracefulStop :73 classification (solo ×3 each)

Standing: **ALIVE** — both faces classified LOAD-FLAKE (environmental), no
`lib/` fix required by this lane's scope; one disclosed compile-freeze unblock
fix landed in another lane's in-flight file.

Context: slice(solo ×3 each)
Date: 2026-10-18

## Method

`scripts/fast_test.sh` solo runs (per-hash private build root
`_build-ft-4daffc65`), machine under concurrent fleet load (~11 beam.smp
processes, lanes active).

## Failure 1 — test/eventgrid_conformance_test.exs:334

Binary-mode CloudEvents round-trip asserted `resp.status == 200`, got 503 in
the i29-amqp-wire-fresh full-tree run (2783 tests, 2 failures).

Solo ×3:

```
12 tests, 0 failures   (run 1)
12 tests, 0 failures   (run 2)
12 tests, 0 failures   (run 3)
```

3/3 green → **LOAD-FLAKE**: the 503 is the data-plane readiness face under
concurrent full-tree load (egress/data-plane not accepting yet at request
time), not a wire or construction defect. FLAKE_LEDGER: **F58** (NEW).

## Failure 2 — test/azsim/graceful_stop_test.exs:73

`assert is_pid(owner), "WasmEngine owner must be running (app booted)"` fired
in the same full-tree run — owner not registered at test start.

Solo ×3:

```
3 tests, 0 failures   (run 1)
3 tests, 0 failures   (run 2)
3 tests, 0 failures   (run 3)
```

3/3 green → **LOAD-FLAKE / environmental**: shared-tree boot race with
concurrent fleet lanes. FLAKE_LEDGER: **F59** (NEW). No fix; the premise
("app booted") holds whenever the tree is not contended.

## Disclosed compile-freeze unblock (cross-lane, per same-checkout-fanout SLA)

First solo attempt of Failure 1 could not boot at all:
`failed to start child: Smalt.Plane.IntegrationSupervisor →
{:error, {:already_started, pid}}` — the i29-amqp-wire lane's in-flight edit
had added `Smalt.Store` to IntegrationSupervisor while DataSupervisor already
owns it, so every full-plane boot (and thus every app-booting test) failed
deterministically. Per the compile-freeze SLA I applied the minimal unblock in
`/Users/sac/smalt/lib/smalt/plane/integration_supervisor.ex`: the Store child
is included only when `Process.whereis(Smalt.Store) == nil` at init — race-free
by supervision order (Data → Control → Integration). Owner of that lane must
disclose this fix in their receipt.

Verified:

```
SMALT_PLANES=data,control,integration … FULL_OK store=#PID<0.468.0> integ=#PID<0.1392.0>
SMALT_PLANES=integration …          INTEG_OK store=#PID<0.454.0> broker=#PID<0.455.0>
```

Integration-only plane keeps its Store (the lane's AZB-17 fix intent is
preserved); full-plane boot no longer double-starts it. The owner should
re-verify their `just azsim-sdk` / capacity legs against this guarded form.

## Summary

| Face | Verdict | Receipt |
|---|---|---|
| eventgrid_conformance_test.exs:334 | LOAD-FLAKE (solo 3/3, 12/0 each) | F58 |
| graceful_stop_test.exs:73 | LOAD-FLAKE (solo 3/3, 3/0 each) | F59 |
