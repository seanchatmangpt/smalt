# Receipt — ex7 fintech-throttle (lane ex7, 2026-10-19)

**Standing: ALIVE** — 10/10 checks GREEN, exit 0, reproduced on two
consecutive full runs (both runs also exercised the self-healing reboot path:
a sibling lane's port sweep SIGTERMed the private beam mid-run and the
harness re-booted, re-minted boot-scoped credentials, and completed green).

## Deliverables

- `/Users/sac/smalt/examples/fintech-throttle/index.ts` — probe harness
- `/Users/sac/smalt/examples/fintech-throttle/run.sh` — self-booting entry
- `/Users/sac/smalt/examples/fintech-throttle/README.md` — business story

## Scope and method

- Private throttle substrate: block `v6` = ports 39760-39765 (verified free
  via `lsof` before use; 39750-39755 is the py MESG lane's block), enforce
  auth, `arm_rate_limit=20` injected via boot-eval `Application.put_env`,
  known SB shared key. Reuse-else-boot with boot marker
  (`/tmp/ex7-fin-throttle.boot.json`), create-exclusive lock, deadline-poll
  health (`/metadata/endpoints` 200). Lane build root `_build-lane-ex7`
  isolates compiles from sibling lanes' in-flight lib/ edits.
- Zero mocks; official `@azure/arm-resources` + `@azure/service-bus` over the
  real wire; no fixed sleeps (Retry-After-honoring retries and deadline-
  bounded waits only); typed SDK exceptions asserted on real state.
- Exit contract: 0 pass / 1 fail / 2 substrate down / 3 loud skip.

## Checks

1. `throttle-substrate-up` — reuse-else-boot healthy.
2. `arm-burst-typed-429` — 60-request burst, `maxRetries:0`: 44 x 429,
   `Retry-After: 1`, `error.code=TooManyRequests`.
3. `arm-429-retry-after` — header present on 429s.
4. `arm-429-typed-code` — typed body code.
5. `arm-burst-no-5xx` — zero 5xx in the burst window.
6. `arm-default-retry-all-succeed` — 40/40 with SDK default retries.
7. `sb-queues-created` — 130/130 queue PUTs under the throttle.
8. `sb-cbs-claim-flow` — CBS put-token accepted, send resolves.
9. `sb-cbs-capacity-typed` — 127 sends then typed rejection
   (`ServiceBusError: InternalServerError CLAIM_CAPACITY`), bounded
   (15 s deadline, `hung=false`); 127+1 = the 128 per-connection claim ceiling.
10. `sb-cbs-capacity-error-class` — over-capacity error
    `instanceof MessagingError` = true.

## Embedded final run output (confirmation run, exit 0)

```
[ex7] booted throttle substrate block=v6 pid=90981 ports=39760/39761/39762/39763/39764/39765
[ex7] REBOOTED throttle substrate pid=91654 (prior beam killed externally; ARM credential will re-mint)

== ex7-fintech-throttle: 10/10 GREEN, 0 FAIL ==
  [GREEN] throttle-substrate-up — block=v6 arm=http://127.0.0.1:39762 tls=https://localhost:39764 amqp=39760 rate_limit=20 reused=false
  [GREEN] arm-burst-typed-429 — burst=60 200x19 429x41 5xx=0 other={} retry-after=1 error.code=TooManyRequests
  [GREEN] arm-429-retry-after — retry-after=1
  [GREEN] arm-429-typed-code — error.code=TooManyRequests
  [GREEN] arm-burst-no-5xx — 5xx count in burst window=0
  [GREEN] arm-default-retry-all-succeed — default-retry client: 40/40 requests eventually succeeded (SDK honored Retry-After)
  [GREEN] sb-queues-created — arm_rate_limit=20, Retry-After-honoring retries; surface=nsPUT=202; created=130/130
  [GREEN] sb-cbs-claim-flow — send to ex7fin1792474305942q0 resolved — attach+flow+CBS put-token claim accepted
  [GREEN] sb-cbs-capacity-typed — claimed+sent=127 before typed rejection; error=ServiceBusError: InternalServerError: CLAIM_CAPACITY hung=false (per-connection claim ceiling=128, one claim consumed by the CBS-flow probe)
  [GREEN] sb-cbs-capacity-error-class — over-capacity error instanceof MessagingError=true
```

## Honest notes

- `down --block v6` returned rc=3 (port occupied after sweep) during runs —
  the private beam was being SIGTERMed mid-run by an external actor
  (sibling-lane sweep / lane-clean; three SIGTERMs visible in
  `/tmp/smalt-substrate-state/logs/v6.log`). The harness's bounded reboot +
  credential re-mint made both final runs complete green over the rebooted
  beam. A blocked-final-sweep is a teardown wart, not a check failure.
- Failed intermediates observed and fixed: SB queue ARM PUT demands a
  `location` payload field (else `400 InvalidResourceShape`); SB namespace
  PUT is a 202 LRO; the SDK uses the conn-string SharedAccessKey verbatim
  for the SAS HMAC (no base64 decode) — the server-side `put_env` key must
  be byte-identical.
- No 5xx leaked anywhere in any leg; no lane shared infra was edited;
  `lib/` untouched.

## Falsifiers

- A rerun where the burst yields 0 x 429 against the declared limit.
- A capacity-leg send that hangs past the 15 s deadline instead of failing
  typed.
- An over-capacity rejection that arrives as a 5xx or an untyped Error.
