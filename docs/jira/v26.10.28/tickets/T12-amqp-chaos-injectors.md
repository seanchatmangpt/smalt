# T-12 — Chaos engineering: AMQP link/credit/session injectors

- window: v26.10.28 · maps-to: Topaz v1.13 "Chaos — AMQP link detach injection · credit starvation · session timeout injection" · verdict-at-open: **PARTIAL**
- size: **M** · depends-on: — · parity-leg: chaos-tier extension (feeds T-14)

## current state (evidence)

smalt's chaos tier exists with different injection points: SIGKILL storms
(receipt `docs/jira/v26.10.18/receipts/azb-14-sigkill-storm.md`),
Store-kill recovery (`test/internal/dets_mirror_recovery_test.exs`), and
throttle profiles (`:cosmos_ru_limit`, `:arm_rate_limit` via boot-eval).
No protocol-level AMQP injectors (map row, source-verified).

## scope

Broker-internal fault flags behind typed config keys (boot-eval
`Application.put_env` discipline, never runtime patching), each with a
bounded injector loop and typed telemetry:

1. `:sb_chaos_detach_after` — force-detach links after N deliveries
   (retryable detach error, real error-shape).
2. `:sb_chaos_starve_credits` — withhold flow credits; deliveries stall
   until the client's retry/credit-drain path fires.
3. `:sb_chaos_session_timeout_ms` — sessions close at the injected
   timeout, exercising client resiliency/reconnect paths.
4. Same trio namespaced for Event Hubs links where the broker is shared.

## non-goals

- Random/probabilistic chaos modes (deterministic, typed, bounded only —
  zero-sleep law and non-vacuity courts apply).
- Network-level fault injection (out of the substrate's reach).

## Definition of Done — the Azure developer's view

You boot the substrate with a chaos flag set (documented one-liner) and
run your `@azure/service-bus` client's error/resume path against it: with
detach injection, every N-th delivery lands in your
`processError` handler with the same retryable error name you see during
Azure maintenance events, and your retry loop recovers without code
changes. With credit starvation, your receiver observes the stall and your
keep-alive/credit logic recovers when you flip the flag off and re-boot.
Session-timeout injection closes your sessions on schedule so your
connection-recreation path is exercised exactly as it would be in
production — your resilience tests run locally, deterministically, every
time.

## receipts required

One injector court per flag (typed fault observed + recovery receipt) +
non-vacuity witness (flag off = zero interference, byte-identical traffic).
