# HRN-011: NFR — Concurrency (parallel workers, no port races)

## Context

vitest runs files in parallel workers; all workers share 127.0.0.1:9443. No worker may
collide on ports or on provisioned names.

## Acceptance

- The suite assumes a single shared substrate port (9443) — no worker binds its own
  listener; tests connect to the substrate, they do not start servers (real-collaborator
  rule: the substrate is the real server).
- Provisioned entity names are worker-unique (worker index + loop seed in the name) so
  parallel workers never collide on unique constraints.
- A concurrency probe: two files run concurrently against the same substrate and both
  complete with zero connection-refused and zero unique-violation failures.

## Falsifier

A harness that starts its own server per worker (violates real-collaborator + creates port
races), or that collides under parallel workers.

## Constraints

Chicago; mocks banned. Shared client + naming helpers at
`apps/api/src/testing/` (client.ts, names.ts).
