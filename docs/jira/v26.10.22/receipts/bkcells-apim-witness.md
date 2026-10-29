# BK-CELLS — PRD-APIM dedicated witness receipt (filing the APIMWIRE checkpoint 1570385 witness)

**Standing:** **ALIVE** (6/6 court green at HEAD, 2026-10-22)

Context: solo

Lane: bkcells. Falsifier clause "the pending receipt filing this witness" on
the VALIDATION v8 PRD-APIM row is closed by this filing.

## What is witnessed

- Smalt.Apim is wired into the live router: lib/smalt/egress_router.ex:370
  (`Smalt.APIM.run/2` — Smalt.Apim.run/2) inside run_apim_gateway/2, config-driven
  via `:smalt, :apim_gateways` (api keys are binaries; default-OFF pass-through).
- Supervised rate-limit ETS counter: Smalt.Apim GenServer init/1 ensure_table
  + persistent_term publish; the counter-reset defect fix (the v1 429-never-
  fired defect) holds: over-quota refusals re-fire across windows.
- 429/401 wire refusals: witnessed by the real-router court
  test/integration/apim_wire_test.exs —
  over-quota typed 429 "TooManyRequests", invalid-JWT typed 401,
  valid emulator-STs JWT admits, jwt-refusal-wins chain order, default-off
  404 pass-through face, echo backend 200 with post-transform header.
- APIMWIRE checkpoint 1570385 (the original UNWITNESSED _LANES.md row) is the
  diff that landed the wiring; this receipt is the witness filing the _LANES
  row lacked.

## Court output (verbatim, exit 0)

$ MIX_BUILD_ROOT=_build-bkcells mix test test/integration/apim_wire_test.exs

    04:49:21.332 info[] GET /apim-gw/apimwire-be085b76db7b/orders/42
    04:49:21.332 info[] Sent 200 in 26µs
    Finished in 0.8 seconds (0.00s async, 0.8s sync)
    Result: 6 passed

## Standing falsifiers (unchanged, carried on the ALIVE row)

- a policy chain that stops being served by the live router, or
- a 429/401 without the supervised ETS counter behind it.

## Note

The court boots its own app (ephemeral ports) — no substrate dependency; the
:apim_gateways config flip is scoped with restore (Chicago-real: the flip is
Application env on the running node, the router reads it per request).
