# P04 — Session persistence under browser concurrency, wire-integrity proven

- window: v26.10.30 · id: CLM-04 (Scenario 2) · receipt: r-p04-concurrent-sessions.md
- depends: FINISH-WIRE wire chain (landed).

## Claim

10+ concurrent browser contexts sharing one authenticated session execute
mutations with zero connection drops, zero `Unknown RESP type` errors in API
logs, and store-level confirmation of session TTL behavior.

## Falsifier

Any pipeline stall, protocol desync, or session loss under concurrency.
