# BK6 — VALIDATION partial-cell closures (SEC-01 / WIRE-02 / OBS-04)

**Standing:** **ALIVE** (all three backlog cells were already receipt-typed ALIVE
on disk — the backlog snapshot was premise rot; the lane's real work was
fresh re-witnessing plus closing the one genuinely open surface, the KD-157
FLIP-PENDING-WITNESS row, whose falsifier this lane ran for real).

Context: solo

Lane: bk6, 2026-10-21, repo /Users/sac/smalt, build root `_build-bk6`
(retained on disk as a lane lease — coordinator deletes at integration).

## Cell-by-cell

### SEC-01 (Go-client leg) — already closed; re-witnessed

The Go-client leg existed on disk before this lane started:
`receipts/goleg-tls13-client.md` (go1.23.4, 6/6 legs, 0 errors). This lane
added a stronger witness: the original GOLEG saw TLS 1.3 only on a private
39975 listener (the live twin was 1.2-pinned); against the current
1.3-default-flipped twin the same harness now answers TLS 1.3:

```
$ go run tmp/goleg_dial.go 127.0.0.1:9444 default|classical|mlkemonly   ×3 (go1.23.4, exit 0 each)
MODE=default(MLKEM-offered) ADDR=127.0.0.1:9444 NEGOTIATED_VERSION=TLS 1.3 CIPHER=TLS_AES_128_GCM_SHA256 HANDSHAKE=OK
MODE=classical ADDR=127.0.0.1:9444 NEGOTIATED_VERSION=TLS 1.3 CIPHER=TLS_AES_128_GCM_SHA256 HANDSHAKE=OK
MODE=mlkemonly ADDR=127.0.0.1:9444 NEGOTIATED_VERSION=TLS 1.3 CIPHER=TLS_AES_128_GCM_SHA256 HANDSHAKE=OK
```

Evidence folded into the AR-SEC-01 row with the receipt path. Residual
unchanged: azidentity auth-flow leg typed-open; go1.23 can't read the
negotiated group.

### WIRE-02 (shim reconciliation) — KD-157 falsifier run, register flipped

The cell (AR-WIRE-02 `is_integer/3`, `receipts/impl11-ar-wire-02-adoption.md`,
ALIVE-on-pinned) had no outstanding shim. The one FLIP-PENDING-WITNESS row in
the canonical register was **KD-157** (`lib/smalt/tls.ex` h2
`max_reset_stream_rate {50_000, 10_000}` backstop, shim mtime 15:05:53): its
close condition required a post-restart ramp witness. Executed:

```
$ MIX_BUILD_ROOT=_build-bk6 just substrate-down; 9>&- MIX_BUILD_ROOT=_build-bk6 just substrate-up
  → beam pid 53160, all 4 ports UP (exit 0; two failed launches on the
    host-toolchain gap 1.19.5-vs-pin left transient lock orphans, cleared)
$ NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem SCVD_CONCURRENCY=128 node scripts/bench/scvd_t21_arm_ramp.mjs   ×2 → exit 0
  transport_retries 539–562 → 0, delete_retry_404_ok=0, errors=0, standing PASS (both runs)
$ elixir --name court@127.0.0.1 --cookie smalt_peer_court -S mix test test/integration/peer_two_node_court.exs
  → Result: 4 passed (56.6 s, exit 0)
$ python3 scripts/kd_flip.py --apply → KD-157 OPEN → CLOSED-SIMULATED (verified: covers-map line "KD-157: [CLOSED-SIMULATED] lib/smalt/tls.ex")
```

Server-side face: every `Stream resets rate exceeded` GOAWAY in
substrate.log timestamps 12:02–12:29 (pre-fix beam); zero post-restart.
Sibling lane bk20 independently ran the same falsifier
(`receipts/bk20-kd157-witness.md`); the register row cites bk20's path
(kd_flip cites the newest post-shim mentioner) — both witnesses carry real
output, no conflict.

### OBS-04 (two-node peer court) — already closed; re-run green

`receipts/obs4court-peer-two-node.md` (ALIVE, 4/4 ×2) already landed and the
cell is typed ALIVE in v6. This lane re-ran the court on the recycled beam:
**4 passed, 56.6 s, exit 0** (distributed runner
`elixir --name court@127.0.0.1 --cookie smalt_peer_court -S mix test ...`;
plain `mix test` yields a loud 4-invalid SKIP by design — the runner must be
distributed). Evidence folded into the AR-OBS-04 row with the receipt path.

## VALIDATION.md state

No verdict flips were owed — every cell verdict already had its receipt on
disk. Folds: AR-SEC-01 evidence + BK6 receipt in the v6 fold list +
provenance, AR-OBS-04 fresh re-run noted, receipt paths named per the
no-receipt-no-flip law (the only register-level flip, KD-157, is
receipt-gated and applied via `scripts/kd_flip.py --apply`).

## Machine

Apple M3 Max · OTP 29.1.2 / Elixir 1.20.4-otp-29 (asdf pin) · go1.23.4 ·
substrate beam pid 53160 on `_build-bk6`.