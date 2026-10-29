# BK-SUBTLS — shared-substrate TLS refusal: diagnosed + repaired

Standing: **ALIVE** (post-repair wire proofs + ctq2 full gate PASS, exit 0). Context: solo.
Date: 2026-10-22. Owner lane: BK-SUBTLS (substrate ops).

## Complaint (from bkbshape-phantom-options.md BLOCKED section)

Main substrate refuses TLS on 9443/9444: curl exit 35 on the STS endpoint
(witnessed twice), cosmos SDK ECONNRESET — blocking ctq2's full gate
(BK-BSHAPE fix rerun was BLOCKED-with-owner on substrate ops).

## Census (step 1)

- Single substrate, not multiple: beam pid 76567 owned 9443/9444/5672/5673
  (lsof before-evidence below). Lock FREE.
- **The substrate was a tree-orphan**: `ps eww 76567` shows
  `MIX_BUILD_ROOT=_build-bkskipport` — a lane build root that no longer exists
  (`ls _build-bkskipport` → No such file or directory; deleted post-boot,
  consistent with the lane-clean law). Its stdout log
  `/tmp/witness-all-substrate.log` names the booter (a witness-all lane).

## Diagnosis (step 2) — lazy code load against a deleted build root

- TLS itself was NEVER broken: served cert on 9444 is byte-identical to
  `.smalt/tls/dev-cert.pem` (sha256 fingerprint
  `BC:08:FD:0F:E7:90:22:D9:90:19:17:0A:51:D4:FC:DD:F8:5C:8C:CD:AC:39:1D:AD:AD:AD:18:89:8C:EA:A3:C8:93`
  both sides), issuer CN=smalt-dev-ca, `SSL certificate verify ok`.
- The refusal was **HTTP/2-only**: curl default (h2) → exit 35/16
  ("Error in the HTTP2 framing layer"); curl `--http1.1` → 401/200 fine.
  node 26 undici/fetch negotiates `alpn h2` (NODE_DEBUG=tls witness) →
  `UND_ERR_SOCKET "other side closed"` = the cosmos SDK's ECONNRESET.
  HTTP/1.1 clients never touched the fault.
- Server-side smoking gun, `/tmp/witness-all-substrate.log` line 70684:

```text
** (UndefinedFunctionError) function Bandit.HTTP2.Handler.handle_connection/2 is undefined
   (module Bandit.HTTP2.Handler is not available)
   ... plug: {Smalt.EgressRouter, []}, http_2_enabled: true
```

  repeated for ArmGateway/Mcp/ConfidentialLedger routers — every h2 connection
  on every Bandit listener (9443/9444/8443/8444/9545; h2 prior-knowledge over
  cleartext also failed) crashed the connection process at lazy module load.
  h1 worked because its modules were loaded at boot, before the build root
  was deleted; h2 loads lazily on first h2 connection.
- Non-causes ruled out by probe: cert mismatch (fingerprint match above),
  stale CA (verify ok), multiple substrates, congestion (flakiness census 8/8
  and 5/5 deterministic), Bandit/OTP-29 h2 bug (a scratch Bandit 1.13.1 on the
  same OTP 29.1.2 toolchain served h2 200 on port 39777), and the
  `max_reset_stream_rate` opt (scratch listener with the same opt also 200).

## Repair (step 3)

1. Typed tree-orphan 76567 stopped via `just substrate-down` (lock-managed).
2. `substrate-up` attempt 1 failed typed: Kafka `{:listen_failed, 9092,
   :eaddrinuse}` — pid 18147 (detached, parent launchd, log
   `tmp/az1_debug_boot.log` "READY KAFKA_PORT=9092", started 00:46) was a
   leftover Kafka-only debug boot: second typed orphan.
   Killed by exact PID with before/after lsof:

```text
BEFORE: beam.smp 18147 ... TCP 127.0.0.1:9092 (LISTEN)
AFTER : 9092 free
```

3. `env -u MIX_BUILD_ROOT SMALT_UP_TIMEOUT=600 just substrate-up 9>&-`
   with the asdf OTP-29 toolchain on PATH (bare `just substrate-up` picks up
   homebrew Elixir 1.19.5 and refuses: mix.exs requires `~> 1.20` — a
   toolchain-routing hazard worth its own row someday). Substrate UP,
   pid 76687, canonical `_build/dev`, lock fd closed, lock released.

## Proof (step 4) — after-evidence

```text
9444 TLS h2 GET x5:  401 401 401 401 401        (was 000 x8)
9444 STS POST:       200 (RS256 bearer, 7.8 ms) (was exit 35/000)
9443 h2 prior-knowledge: 401 (served)            (was 000)
9443 metadata/endpoints: 200
9444 undici/fetch (h2):  401                     (was UND_ERR_SOCKET x6)
8443 plain h1: 401 · 8444 ledger plain: 404 · 9545 MCP: 200
```

**ctq2 full gate** (`NODE_EXTRA_CA_CERTS=$PWD/.smalt/tls/ca-cert.pem CTQ2_N=50
node scripts/bench/ctq2_txn.mjs`, live enforce-mode substrate):

```text
EMIT txn/cold n=50 p50=7.64 p95=10.514 p99=11.88 err=0
EMIT txn/warm n=50 p50=5.206 p95=5.708 p99=6.399 err=0
VERDICT PASS: cold p99=11.88ms (<=500), warm p99=6.399ms (<=15), errors=0
```

Exit 0 — **all five legs green including SB (enforce-mode SASL) and the
BK-BSHAPE-fixed cosmos CAS put** (`accessCondition` shape, `1-cosmos-cas-put`
step p50 1.65 ms warm — consistent with the lane-b6 step-level numbers).
Output: `tmp/bench/ctq2-txn.jsonl` (verdict row `"verdict":"PASS"`).
The bkbshape BLOCKED-with-owner row is discharged: rerun
`CTQ2_N=50 node scripts/bench/ctq2_txn.mjs` expectation met with timings
unchanged. BK-WIT's witness-all substrate was the orphan itself; its rerun is
now unblocked against a canonical-build substrate.

## Residual (typed, non-blocking)

- 8443/8444 are CLEARTEXT egress/ledger listeners in this boot ("Running ...
  at 127.0.0.1:8443 (http)"); https probes to them reset by design
  ("Connection that looks like TLS received on a clear channel"). Not a defect.
- Toolchain routing: substrate.sh inherits PATH; a lane whose PATH has
  homebrew Elixir 1.19.5 cannot boot (mix.exs `~> 1.20`) and a lane booting
  with MIX_BUILD_ROOT set leaks a tree-orphan substrate if lane-clean deletes
  the root post-boot. Both are process hazards, registered here; no mechanism
  changed by this lane.

## Replay

```bash
just substrate-status
curl -s --cacert .smalt/tls/ca-cert.pem -o /dev/null -w '%{http_code}\n' https://localhost:9444/
NODE_EXTRA_CA_CERTS=$PWD/.smalt/tls/ca-cert.pem CTQ2_N=50 node scripts/bench/ctq2_txn.mjs
```
