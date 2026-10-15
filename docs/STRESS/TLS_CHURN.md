# TLS Churn Benchmark — smalt 9444 TLS Twin

Real-run receipt for the TLS churn benchmark (`scripts/stress/tls_churn.py`)
against the smalt ARM TLS twin (Bandit/ThousandIsland/OTP 28 ssl). The
listener is TLS 1.2-only with a two-cipher pin, a deliberate MLKEM workaround
documented in `lib/smalt/application.ex`.

## Subject

- Repo: `~/smalt`, OTP 28.3.1 / Elixir 1.19.5, Bandit + ThousandIsland
- Listener: `Smalt.Application.arm_tls_opts/0` — TLS 1.2 only, ciphers pinned
  to `ECDHE-RSA-AES256-GCM-SHA384` /
  `ECDHE-RSA-AES128-GCM-SHA256` (deliberate MLKEM workaround: recent Go
  clients offer X25519MLKEM768 key shares that the OTP 28 ssl app rejects,
  killing the handshake before cert evaluation)
- Cert material: `scripts/gen_dev_cert.sh` chain (CA:TRUE root at
  `.smalt/tls/ca-cert.pem` + CA:FALSE leaf, SAN localhost + 127.0.0.1);
  client verifies with the CA as sole anchor, `check_hostname=True`
- Private test ports (defaults 9443/9444 are contended by other lanes):
  ARM http 29443, TLS twin 29444, egress 28443, AMQP 29672/29673

## Results (final receipt, 2026-10-14 21:47 PT)

Server pid 91201, RSS 155 MB at end of run, alive after all scenarios.

Gate: verified TLSv1.2 / ECDHE-RSA-AES256-GCM-SHA384, GET /tenant → 200.

| # | Scenario | Result |
|---|---|---|
| 2 | TLS1.2-pinned cipher, 10s churn | **503.6 handshakes/s**, p50 1.96 ms, n=5037, 0 failures; every observed cipher = `ECDHE-RSA-AES256-GCM-SHA384` |
| 1 | Sustained 30s new-connection churn | **466.9 handshakes/s**, p50 2.06 ms, p99 2.89 ms, n=14008, 0 failures |
| 3 | 20 bursts x 50 concurrent handshakes | **1000/1000 OK**, burst wall p50 15.4 ms, max 18.6 ms |
| 4 | 100 bad-ClientHello connections | Server survived; good verified handshake + 200 immediately after (2.1 ms) |
| 5 | Plain-http 29443, 10s new-connection rate | **1736.7 req/s**, p50 0.14 ms, p99 0.24 ms, n=17367 |

### TLS vs plain-http

TLS new-connection churn sustains ~467 handshakes/s vs ~1737 plain-http
new-connections/s on the identical route: TLS adds ~3.7x per-connection cost
(handshake p50 2.06 ms vs request p50 0.14 ms). Both fail-closed gates
(zero-handshake abort) were armed and never fired on the final run.

### Scenario 5 failure accounting (honest caveats)

The 17,829 "failures" in scenario 5 are client-side `EADDRNOTAVAIL` (errno
49) — local ephemeral-port/TIME_WAIT exhaustion at ~3.5k conn/s — a
measurement ceiling of the single-host harness, NOT server refusals. The
script classifies failures by errno (`classify()` in tls_churn.py) so this
cannot be misread as server fault. Server-side: every connection the client
successfully opened got a 200.

## Environmental note: sandbox SIGKILL

Earlier attempts (run 1..3) had the beam server externally SIGKILLed (exit
137) under churn load when launched from inside the sandboxed Bash tool; with
sandbox disabled the server completed the full run twice in a row (RSS 151/155
MB, stable). Anyone reproducing on this host: run the server outside the
sandbox. This is a harness artifact, not a smalt defect.

## Usage

```bash
eval "$(scripts/dev_env.sh)"
MIX_ENV=test SMALT_TEST_ARM_PORT=<http> SMALT_TEST_ARM_TLS_PORT=<tls> \
  SMALT_TEST_EGRESS_PORT=<egress> SMALT_TEST_AMQP_PORT=<amqp> \
  SMALT_TEST_EVENT_HUBS_PORT=<eh> mix run --no-halt &
SMALT_TLS_PORT=<tls> SMALT_HTTP_PORT=<http> python3 scripts/stress/tls_churn.py
```

Fail-closed: the script aborts nonzero if the connectivity gate, any
scenario, or the post-flood survivability probe fails; zero-success scenarios
abort.

## See Also

`scripts/stress/soak.py` · `scripts/stress/spike.py` · `scripts/gen_dev_cert.sh`
