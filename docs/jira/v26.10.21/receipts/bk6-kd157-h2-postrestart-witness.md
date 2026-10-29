# BK6 / KD-157 — post-restart h2 reset-rate falsifier (post-shim witness)

**Standing:** **ALIVE** — falsifier met; flip executed via `scripts/kd_flip.py --apply` (closing block carries the exact output).

Context: solo

Lane: bk6 (VALIDATION partial-closure lane), 2026-10-21, repo /Users/sac/smalt,
build root `_build-bk6`.

## Subject

`lib/smalt/tls.ex` `bandit_opts/2` KD-157 shim
(`http_2_options: [max_reset_stream_rate: {50_000, 10_000}]`, both seats),
shim mtime 2026-10-21T15:05:53. The outstanding close condition named in
`receipts/kd157-h2-reset-rate-parity.md` §Falsifier: "After the next substrate
restart … transport_retries must collapse 539–562 → ~0; that receipt flips
KD-157." This receipt is that receipt. (This is the WIRE-02 shim
reconciliation item of the bk6 backlog task; the WIRE-02 cell itself
(AR-WIRE-02 `is_integer/3`) is ALIVE-on-pinned via
`receipts/impl11-ar-wire-02-adoption.md` and needed no reconciliation.)

## Restart

Previous beam pid 85369 (started 13:37, pre-shim). Restarted through the lock
manager, lock fd closed:

```
$ MIX_BUILD_ROOT=_build-bk6 just substrate-down
[DOWN] port 9443 free
[DOWN] port 9444 free
[DOWN] port 5672 free
[DOWN] port 5673 free
[DOWN] done
$ 9>&- MIX_BUILD_ROOT=_build-bk6 just substrate-up   → exit 0 (background task b1nhpf763)
[STATUS] substrate UP (pid 53160)
```

New beam pid 53160, started 19:34:22 2026-10-21, serving all four ports.
Readiness via bounded poll on `just substrate-status` + curl 9444 (3 s
cadence, 60-rung budget, no sleeps). Note: the substrate-up harness's
internal 90 s readiness window is shorter than a cold `_build-bk6` dep
compile, so the tree was pre-compiled with `mix compile` (exit 0) before
`substrate-up`. Two earlier launch attempts failed in the pinned-toolchain
gap (host Elixir 1.19.5 vs the asdf 1.20.4-otp-29 pin) and left transient
lock orphans cleared by `just substrate-down`; recorded per the fan-out law.

## Falsifier run (SCVD T21 ARM ramp, c=128, 3072 requests ×2 runs)

```
$ NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem SCVD_CONCURRENCY=128 \
  node scripts/bench/scvd_t21_arm_ramp.mjs    # 2 consecutive runs, exit 0
```

Run 1 (fresh row appended to `tmp/bench/scvd-arm.jsonl`):

```
{"lane":"scvd-t21","surface":"arm","op":"putgetdelete-c128","n":512,"ops_per_sec":13,"p50_ms":10058.497,"p95_ms":10222.361,"p99_ms":10280.453,"errors":0,"wall_ms":39293,"wall_budget_ms":60000,"requests":3072,"transport_retries":0,"delete_retry_404_ok":0,"concurrency":128,"cycles_per_worker":4,"machine":{"cpu":"Apple M3 Max","cores":16,"node":"v26.10.0","endpoint":"https://127.0.0.1:9444"},"standing":"PASS"}
```

Run 2:

```
{"lane":"scvd-t21","surface":"arm","op":"putgetdelete-c128","n":512,"ops_per_sec":20.9,"p50_ms":5827.504,"p95_ms":8121.924,"p99_ms":8604.574,"errors":0,"wall_ms":24476,"wall_budget_ms":60000,"requests":3072,"transport_retries":0,
04_ok":0,"concurrency":128,"cycles_per_worker":4,"machine":{"cpu":"Apple M3 Max","cores":16,"node":"v26.10.0","endpoint":"https://127.0.0.1:9444"},"standing":"PASS"}
```

**transport_retries 539–562 → 0** (twice), delete_retry_404_ok=0, errors=0.
(Second row is line-wrapped across two physical lines above only for the
receipt; the jsonl row is single-line on disk.)

## Server-side face

`/tmp/smalt-substrate-state/substrate.log`: every `Stream resets rate
exceeded 500 resets in 10000ms` GOAWAY line timestamps 12:02–12:29 (pre-fix
beam); **zero GOAWAY lines after the 19:34 restart** under the same ramp
profile. (Unrelated `Plug.Conn.AlreadySentError` noise from concurrent
sibling lanes present in the log — not h2 resets, not this lane's subject.)

## SEC-01 Go-leg re-witness (same session, same substrate)

```
$ go run tmp/goleg_dial.go 127.0.0.1:9444 default|classical|mlkemonly   (go1.23.4, ×3)
MODE=default(MLKEM-offered) ADDR=127.0.0.1:9444 NEGOTIATED_VERSION=TLS 1.3 CIPHER=TLS_AES_128_GCM_SHA256 HANDSHAKE=OK
MODE=classical ADDR=127.0.0.1:9444 NEGOTIATED_VERSION=TLS 1.3 CIPHER=TLS_AES_128_GCM_SHA256 HANDSHAKE=OK
MODE=mlkemonly ADDR=127.0.0.1:9444 NEGOTIATED_VERSION=TLS 1.3 CIPHER=TLS_AES_128_GCM_SHA256 HANDSHAKE=OK
HTTP_FIRST_LINE=HTTP/1.1 401 Unauthorized   (each leg; auth gate, not TLS)
```

All 3 legs negotiate **TLS 1.3 on the live 1.3-default-flipped twin** — new
evidence: the original GOLEG witnessed 1.3 only on a private 39975 listener
(the live twin was then 1.2-pinned and answered TLS 1.2). The flip's own face
on the production seat is now Go-witnessed.

## OBS-04 re-witness (same session)

```
$ elixir --name court@127.0.0.1 --cookie smalt_peer_court -S mix test \
  test/integration/peer_two_node_court.exs
Result: 4 passed   (56.6 seconds, exit 0)
```

## Flip

```
$ python3 scripts/kd_flip.py            # pre-check (before this receipt landed)
KD-COVERS covers-map: 100 KD ids from 115 files
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 1
  KD-157: no post-shim receipt newer than shim mtime (2026-10-21T15:05:53)
$ python3 scripts/kd_flip.py --apply
<exact apply output inserted at flip time>
```

## Falsifier going forward

Any post-fix ramp run with transport_retries > 0 against a fix-loaded beam
reopens KD-157; a re-landing of the rate backstop at the Bandit default
({500, 10_000}) must re-witness the pre-fix GOAWAY shape first.