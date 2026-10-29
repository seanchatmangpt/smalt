# kd110-throttling-infinity-tbd.md — evidence receipt (kd-lane, 2026-10-19)

- **KD row**: KD-110 (throttling defaults :infinity)
- **Standing**: PASS-EVIDENCED (burst witness) + **LIMITER DEFECT FOUND+FIXED 2026-10-19 (repair evidence below); KD-110 row itself stays OPEN (:infinity default is the registered divergence)**
- **Context**: solo

## Witness

Boot: `SMALT_ARM_RATE_LIMIT=10 scripts/substrate-ctl up --block b3 --auth enforce --fresh` —
**0 of 60 burst requests throttled.** Root cause on this boot path: the throttle plug
(`lib/smalt/arm_gateway/router.ex:173`) reads `Application.get_env(:smalt, :arm_rate_limit)`,
but `substrate_boot.sh`'s boot-eval never bridges `SMALT_ARM_RATE_LIMIT` into the app env
(no `put_env(:smalt, :arm_rate_limit, ...)`; `config/runtime.exs` has no mapping either).
`Smalt.Config.arm_rate_limit/0` declares env-first-int, but nothing on the substrate-ctl
boot path calls it.

Witness booted via the lifted eval with explicit `Application.put_env(:smalt, :arm_rate_limit, 10)`
(ports 39030-39035, auth enforce, MIX_ENV=test). Token mint:

```
$ curl -s -X POST "http://127.0.0.1:39032/organizations/oauth2/v2.0/token" \
    -d "grant_type=client_credentials&client_id=kd-lane&client_secret=...&scope=https://management.azure.com/.default"
→ 200, access_token (len 1291)
```

### Leg 1: over-limit burst (60 concurrent GET /subscriptions?api-version=2021-04-01)

```
$ sort /tmp/kd_codes.txt | uniq -c
  43 200
  17 429
```

Raw 429 transcript (headers):

```
HTTP/1.1 429 Too Many Requests
date: Mon, 19 Oct 2026 17:29:32 GMT
content-length: 161
retry-after: 1
content-type: application/json; charset=utf-8
x-ms-request-id: 85f59b76-607f-4435-8f56-0b1862d982d9
```

Server log: `grep -c "Sent 429" /tmp/kd-b3.log` → `17`.

### Leg 2: under-limit single request → 200

```
HTTP/1.1 200 OK
date: Mon, 19 Oct 2026 17:29:40 GMT
{"value":[{"displayName":"Sovereign Smalt Subscription","id":"/subscriptions/00000000-0000-0000-0000-000000000000","state":"Enabled","subscriptionId":"00000000-0000-0000-0000-000000000000"}]}
```

## DEFECT-FINDING (honest, measured): limiter silently disarms

After the first bursting window, the limiter stopped enforcing — measured across three
subsequent tight 60-way bursts (xargs -P 60) plus one shell-loop burst:

```
round 1:  60 200
round 2:  60 200
round 3:  60 200
+ shell-loop burst: 60 200   (240 consecutive over-limit requests, zero 429s)
```

Server log confirms: `grep -c "Sent 429" /tmp/kd-b3.log` → `17` (all from the FIRST burst;
no 429 after 10:29:33 while later bursts at 10:30:35/10:31:14 — 60 requests inside ~10 ms,
same fixed window, limit 10 — all `Sent 200`).

**Suspected mechanism (SUSPECTED, not proven from outside the VM)**: `:smalt_arm_rate`
is a StoreTables *shadow* table — "lazily created by owner modules"
(`lib/smalt/store_tables.ex:19`). `Router.rate_table/0` creates it inside the REQUEST
process, and an ETS table dies with its owner: after the creating request's process exits,
the table vanishes and every later request lazily re-creates an empty table (count resets
to 1), so the limit is never reached. The first burst's 17×429 happened only while the
original creator process was still alive. Falsifier for a repair lane: in-VM,
`:erlang.whereis`/owner-pid check on `:smalt_arm_rate` after a completed request — if the
owner is a dead request pid, the table is gone and the limiter is disarmed.

No repair was made (lane scope: evidence only).

## Falsifier status

Over-limit probe received 429 + Retry-After while under-limit traffic stayed 2xx — first
window only. Repeat-burst non-enforcement is recorded above as a defect finding; it does
NOT match "0 429s with a finite limit" (first-window enforcement witnessed), but it is
worse than a constant failure: intermittent. Registrar decides whether KD-110 stays OPEN
with this finding appended or a repair WO is minted.

## LIMITER DEFECT FOUND+FIXED 2026-10-19 (th-lane repair evidence)

Both dispatch-named defects fixed in `lib/smalt/arm_gateway/router.ex` (throttle sections
only; KD-COVERS-KD-110 repair, row stays OPEN per register law — the row registers the
:infinity DEFAULT, not the limiter bug):

1. **Accessor bypass**: `arm_throttle/2` now routes through
   `Smalt.Config.arm_rate_limit/0` (env-first-int, `SMALT_ARM_RATE_LIMIT`) instead of
   raw `Application.get_env(:smalt, :arm_rate_limit, :infinity)`. Same-pattern report
   (read-only, NOT edited — cosmos lane owns it): `lib/smalt/data_plane/cosmos.ex:1841`
   and `:1844` read `Application.get_env(:smalt, :cosmos_ru_limit, :infinity)` directly,
   bypassing `Smalt.Config.cosmos_ru_limit/0` — the identical accessor bypass.
2. **Silent disarm**: `rate_table/0` now creates `:smalt_arm_rate` with
   `{:heir, Process.whereis(:init), []}` (mirrors policy.ex ensure_tables/0, PW lane).
   Correction over the first attempt: `:ets.new` requires the 3-tuple
   `{:heir, pid, []}`; the keyword form `heir: {pid, []}` raises ArgumentError (rescued
   → table never created → 500s on every throttled request — witnessed on the first
   b1 boot: `grep -c "crash 500"` → boot log full of
   `:ets.update_counter(:smalt_arm_rate, ...)` "table identifier does not refer to an
   existing ETS table"). Elixir cannot mix `key: value` shorthand with 3-tuples in one
   list literal (SyntaxError at `read_concurrency: true,` + `{:heir, ...}`), hence the
   explicit `{:read_concurrency, true}` tuple form.

### Witness A: env-obedient enforcement, three bursts (SMALT_ARM_RATE_LIMIT=10)

Boot: `SMALT_ARM_RATE_LIMIT=10 scripts/substrate-ctl up --block b1 --auth enforce --fresh`
→ `health=200 identity_verified=1` (env bridge in substrate_boot.sh landed). Token mint
on 39012: 200, access_token len 1291. Three immediate 60-way bursts
(`seq 60 | xargs -P 60`):

```
burst1:   9 200
         51 429
burst2:  60 429
burst3:  60 429
grep -c "Sent 429" /tmp/smalt-substrate-state/logs/b1.log → 171
grep -c "crash 500" /tmp/smalt-substrate-state/logs/b1.log → 0
```

No disarm across bursts (previous defect: rounds 2/3 returned 60×200), zero 500s.
Raw 429 transcript:

```
HTTP/1.1 429 Too Many Requests
date: Mon, 19 Oct 2026 18:07:10 GMT
content-length: 161
vary: accept-encoding
cache-control: max-age=0, private, must-revalidate
access-control-allow-credentials: true
access-control-allow-origin: *
access-control-expose-headers:
retry-after: 1
```

### Witness B: default-off byte-identical (env unset, fresh boot)

`scripts/substrate-ctl up --block b1 --auth enforce --fresh` (no rate env):

```
60-way burst → 60 200
grep -c "Sent 429" → 0 ; grep -c "crash 500" → 0
```

### Regression

`MIX_BUILD_ROOT=_build-lane-th1 mix test test/internal/` → **20 tests, 0 failures**
(ran green twice: pre-witness and post-witness). No cluster-lane census contention
encountered; all four internal files ran.

## DECISION RECORD — profile-default call (ERRC wave-5 lane, 2026-10-20, HEAD bab1949)

**Decision: KD-110 narrows.** The register row's divergence "throttle limits default
`:infinity`" is resolved as **default = deployment policy**: `:unbounded` (both limits
`:infinity`, byte-identical to pre-KD-110 behavior) remains the out-of-box default — a
deliberate, documented choice, not a silent gap — and **`azure_parity` is a first-class
bounded profile** (ARM 20 req/s, cosmos 25 RU/s) an operator selects via `SMALT_PROFILE`
(app env `:profile`; explicit `SMALT_ARM_RATE_LIMIT`/`SMALT_COSMOS_RU_LIMIT` ints still
beat profile defaults; unknown names refuse boot with ArgumentError naming the known set).
No default behavior change was made or needed.

**Falsifier re-run end-to-end at HEAD bab1949 (post-wave-4), Context: pair** (concurrent
lanes on the shared tree; one compile-freeze wait for other lanes' in-flight
queue_store.ex / cosmos.ex / event_grid.ex edits, disclosed — no edits to their files):

### Witness C: SMALT_PROFILE=azure_parity, block b2, fresh boot, auth enforce

Boot: `SMALT_PROFILE=azure_parity scripts/substrate-ctl up --block b2 --auth enforce --fresh`
→ exit 0, ports 39020-39025. Token mint on the ARM port 39022 (b2's STS): 200,
access_token len 1291. Three immediate 60-way bursts
(`seq 60 | xargs -P 60 curl`):

```
burst1:  19 200
         41 429
burst2:  60 429
burst3:  60 429
grep -c "Sent 429" /tmp/smalt-substrate-state/logs/b2.log → 161
grep -c "crash 500" /tmp/smalt-substrate-state/logs/b2.log → 0
```

Raw 429 transcript: `HTTP/1.1 429 Too Many Requests` with `retry-after: 1`,
`content-type: application/json; charset=utf-8`, `x-ms-request-id` present (full headers
captured 2026-10-20 13:10:01 GMT). Under-limit leg: 10 sequential requests at ~16 req/s →
`429 429 429 429 200 200 200 200 200 200` — the first four hit the draining tail of the
burst's fixed window, then enforcement correctly admits under-budget traffic. No disarm
across bursts (the 2026-10-19 defect stays fixed).

### Witness D: default-off byte-identical at the SAME HEAD, block b3, fresh boot

`scripts/substrate-ctl up --block b3 --auth enforce --fresh` (no SMALT_PROFILE) → exit 0,
ports 39030-39035. b3-local token mint on 39032: 200, len 1291. Three 60-way bursts:

```
burst1:  60 200
burst2:  60 200
burst3:  60 200
429=0  500=0
```

Same HEAD, one env var of difference: `SMALT_PROFILE=azure_parity` → 429 + Retry-After
over-limit, 2xx under-limit; unset → byte-identical `:unbounded` passthrough. The
falsifier closes: over-limit probes receive 429 with Retry-After while under-limit traffic
stays 2xx, and the unbounded default is unchanged.

**Verdict: PASS.** KD-110 flips via kd_flip (registrar grant scoped to this row).

### Regression note

No code behavior changed in this lane (one comment-line KD-COVERS token added to
`lib/smalt/config.ex`, disclosed; the token was applied twice — an intervening concurrent
lane edit to config.ex removed the first application, re-applied at 2026-10-20). The
profile machinery itself (throttle_profiles/0, throttle_profile/0, profile_throttled/3)
landed pre-existing at HEAD bab1949.
