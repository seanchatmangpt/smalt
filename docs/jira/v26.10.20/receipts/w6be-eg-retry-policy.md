# w6be — Event Grid retryPolicy honored by the delivery engine

**Standing:** ALIVE (module tier)
Context: solo
Date: 2026-10-20

## Surface (all additive to `lib/smalt/messaging/event_grid.ex`)

- `subscribe/4` opts `:retry_policy` — `{max_delivery_attempts, event_time_to_live}`.
  - `max_delivery_attempts` integer **1..30** (default 30); out-of-range → typed `ArgumentError` at subscribe.
  - `event_time_to_live`: positive integer **seconds** (smalt extension — real Event Grid uses hours/ISO-8601; seconds accepted so the TTL law is exercisable at emulator scale), `{:hours, n}`, or ISO-8601 `PTnH/PTnM/PTnS`; default `{30, 86_400}`.
  - Recovery re-subscribe preserves the stored policy (mirrors the landed schema law: recovery cannot mutate subscription config).
- **max_delivery_attempts enforcement**: the `dlq_step` budget guard reads the per-sub `max_delivery_attempts` (broker DLQ default as fallback). Exhausted budget → `spill_to_dlq` → real blob DLQ with `x-ms-meta-DeadLetterReason=MaxDeliveryAttemptsExceeded`, typed `{:dead_lettered, ...}` face + `[:smalt, :event_grid, :dead_lettered]` telemetry (reason `:max_delivery_attempts_exceeded`). DLQ disabled → the landed never-loss law is unchanged (no spill without a configured dead-letter destination — real Event Grid likewise requires one).
- **event_time_to_live enforcement**: `dispatch/2` drops TTL-expired queued entries before the delivery attempt — never delivered, typed `[:smalt, :event_grid, :ttl_expired]` telemetry per drop. The publish-time stamp `ts` is the TTL anchor (stable across redeliveries).
- ISO-8601 `PTnH/PTnM/PTnS` + `{:hours, n}` forms validated, normalized to seconds.

## Witness (real output, 17/17 legs true)

Replay: `elixir -pa "_build-lane-w6be/test/lib/*/ebin" -e 'Code.require_file("tmp/w6be_witness.exs")'`
(after `MIX_BUILD_ROOT=_build-lane-w6be MIX_ENV=test mix compile` green)

```
F0_VALID_OK=true
F0_MAX0_REFUSED=true
F0_MAX31_REFUSED=true
F0_TTL0_REFUSED=true
F0_TTLNEG_REFUSED=true
F0_TUPLE1_REFUSED=true
F0_ISO_REFUSED=true
F1_DELIVERED_COUNT1=true
F2_DLQ_BLOB_EXISTS=true
F3_DLQ_META_REASON_ATTEMPTS=true
F4_DLQ_TELEMETRY=true
F5_LIVE_DELIVERY_OK=true
F6_AGED_QUEUED_WHILE_DOWN=true
F7_AGED_PENDING_BEFORE_RECOVERY=true
F8_EXPIRED_NEVER_DELIVERED=true
F9_TTL_TELEMETRY=true
F10_FRESH_DELIVERY_AFTER_DROP=true
W6BE WITNESS: DONE
```

Legs: F0 = validation faces (max out-of-range 0/31, ttl 0/neg, non-tuple, bad ISO-8601 all typed-refused; valid {2,60} admitted). F1 = policy max=2: live delivery attempt 1 (aeg-delivery-count 1). F2/F3/F4 = subscriber killed → redeliver timer consumes the per-sub budget → real blob DLQ `eg-dlq/eg-dlq-s1/0-e1.json` with `x-ms-meta-DeadLetterReason=MaxDeliveryAttemptsExceeded`, attempts "2", dead_lettered telemetry (reason :max_delivery_attempts_exceeded). F5–F10 = policy TTL=1s: live delivery+ack ok; event queued while DOWN, aged past TTL (TIME-ADVANCE — the law under test), recovery drops it (never delivered, ttl_expired telemetry), fresh e4 still delivers count=1.

## Notes

- DLQ-disabled behavior unchanged (landed never-loss law; real Event Grid also requires a dead-letter destination to spill).
- Two receipt-draft Writes corrupted mid-body this lane (the wave's generation-integrity class) — rebuilt via heredoc; the witness and lib/ edits were unaffected (all writes syntax-gated).
- Falsifier: green under a broken budget guard (e.g. attempts never advancing past 1) or a dispatch that delivers expired entries would flip F2/F3/F8/F9 red.

## RE-WITNESS addendum — 2026-10-22 (lane BK-REWIT3): cheap replay PASS — ALIVE

Re-ran `tmp/w6be_witness.exs` on `_build-rewit3` (`mix run --no-start`):
all 17 legs `=true` (F0_VALID…F10_FRESH_DELIVERY_AFTER_DROP) and
`W6BE WITNESS: DONE`, exit=0 — 17/17 exactly as the original witness.
SUSPECT cleared; ALIVE on the integrated tree.
