# ex7 — Fintech throttling resilience

## The business problem

A payments platform's control plane is regulator-capped: its ARM surface
admits at most 20 requests per fixed window (`arm_rate_limit=20`). When a
deploy fan-out fires a burst of control-plane calls, the platform needs a
guarantee: over-limit demand is answered with a **typed 429 TooManyRequests
carrying `Retry-After`** — never a 5xx — so SDK retry policies can back off
and every operation lands eventually. Meanwhile the payment channel itself is
a single AMQP connection whose CBS token claims are capacity-bounded; the
platform needs to know that crossing the claim ceiling is a **typed, bounded
rejection** — never a hang on the payments hot path.

This example proves both guarantees against the real wire.

## What it runs

Boot: a lane-private throttle substrate (block `v6`, ports 39760-39765,
enforce auth, `arm_rate_limit=20` via boot-eval `Application.put_env`) —
reuse-else-boot with boot marker + lock + deadline-poll, and self-healing
reboot (re-minting boot-scoped credentials) if a sibling lane's sweep kills
the beam mid-run.

1. **Burst leg** — 60 concurrent ARM GETs through `@azure/arm-resources`
   with `retryOptions.maxRetries: 0`: asserts a typed 429 with `Retry-After`
   and `error.code=TooManyRequests`, and **zero 5xx** in the burst window.
2. **Default-retry leg** — 40 sequential ARM GETs with the SDK's default
   retry policy: all 40 eventually succeed (the SDK honors `Retry-After`).
3. **Queue provisioning under throttle** — 130 queue PUTs through the
   ARM rate limiter with Retry-After-honoring retries: 130/130 created.
4. **Service Bus CBS leg** — one real AMQP connection:
   - CBS put-token claim flow succeeds for a first audience (send resolves);
   - fanning sends across 130 distinct queue audiences crosses the
     per-connection claim ceiling (128): the over-capacity send fails
     **typed** (`ServiceBusError`, `MessagingError` instance) within a
     bounded 15 s deadline — never a hang;
   - over-capacity error verified `instanceof MessagingError`.

## Run

```bash
bash examples/fintech-throttle/run.sh
```

Exit contract: 0 pass / 1 fail / 2 substrate down / 3 loud skip. The harness
sweeps its own block on exit; the AMQP queue plane auto-vends entities on
attach, so no manual entity setup is needed.

## Wire notes (observed on the substrate)

- The fixed window is 1 s (`lib/smalt/arm_gateway/router.ex`), `Retry-After: 1`.
- SB queue ARM PUT requires a `location` field in the payload; omitting it
  answers `400 InvalidResourceShape`.
- SB namespace PUT is an LRO (`202` + async operation).

See Also: `verification/README.md` (wf5 throttle pattern), `verification/ts/wf5/index.ts`
