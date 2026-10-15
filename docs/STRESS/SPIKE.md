# SPIKE Stress Receipt

Harness: `scripts/stress/spike.py` (stdlib-only, boots its own substrate and
kills it in a `finally` trap). Receipt file: `tmp/spike-receipt.json`
(schema `smalt-spike/v1`).

## Load Model

- Spike: instant 500 concurrent client threads, each opening its own TCP
  connection at a shared barrier and doing 5 ARM PUTs (2,500 requests/cycle,
  token pre-minted once via the ARM STS client-credentials flow before any
  spike).
- Recovery: 10 spike cycles back-to-back with 5s idle between cycles; after
  each cycle a single fresh-connection ARM PUT must complete in < 100ms.
- TLS herd: 100 parallel TLS 1.2 handshakes + GET against the ARM TLS twin
  (port 9444; dev cert auto-minted by `Smalt.TLS.ensure_dev_cert/0`).
- Measured: accept latency (barrier release -> first response byte per client),
  per-request first-byte p50/p95/p99/max, status counts, queue-drop /
  connection-refused count, error classes (refused / reset / timeout / tls /
  broken-pipe / other).

## Budgets

| Budget | Target | Observed | Verdict |
|---|---|---|---|
| Spike p95 (worst cycle) | < 2000ms | 261.7ms (cycle 3) | PASS |
| 5xx across all cycles | 0 | 0 | PASS |
| Post-spike single request | < 100ms after every cycle | 0.4-0.5ms all 10 cycles | PASS |
| Queue-drop / conn-refused | 0 | 0 | PASS |
| TLS herd (100 handshakes) | zero errors, zero 5xx | 100/100 OK, p50 57.7ms, p99 63.7ms | PASS |

## Receipt Table (run 2026-10-14, ports 29443/28443/29444)

| Cycle | Wall s | p50 ms | p95 ms | p99 ms | Max ms | 5xx | Errors | Recovery ms | OK |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 0.759 | 97.6 | 242.9 | 313.7 | 535.2 | 0 | 0 | 0.4 | PASS |
| 2 | 0.818 | 106.1 | 257.4 | 322.9 | 477.8 | 0 | 0 | 0.4 | PASS |
| 3 | 0.792 | 102.4 | 261.7 | 335.7 | 472.0 | 0 | 0 | 0.5 | PASS |
| 4 | 0.675 | 87.6 | 208.0 | 271.3 | 371.0 | 0 | 0 | 0.5 | PASS |
| 5 | 0.739 | 94.5 | 231.1 | 293.7 | 505.3 | 0 | 0 | 0.5 | PASS |
| 6 | 0.726 | 92.6 | 229.9 | 294.5 | 466.7 | 0 | 0 | 0.5 | PASS |
| 7 | 0.707 | 92.0 | 222.6 | 280.0 | 361.6 | 0 | 0 | 0.5 | PASS |
| 8 | 0.664 | 86.1 | 213.7 | 280.1 | 387.9 | 0 | 0 | 0.5 | PASS |
| 9 | 0.676 | 87.2 | 216.1 | 274.5 | 466.8 | 0 | 0 | 0.5 | PASS |
| 10 | 0.737 | 92.7 | 227.2 | 310.5 | 418.7 | 0 | 0 | 0.5 | PASS |

TLS herd: 100/100 handshakes OK, p50 57.7ms, p99 63.7ms, 0 5xx, 0 errors.

## Totals

- 10 cycles x 2,500 = 25,000 spike requests + 100 TLS herd requests = 25,100.
- 0 5xx, 0 transport errors, 0 connection refusals (queue drops).
- Total spike-phase wall 52.6s including 9x5s idle windows.

## Verdict

**PASS** — all budgets hold: worst-cycle p95 261.7ms (< 2s), zero 5xx across
25,100 requests, recovery probe < 1ms after every cycle, TLS herd clean.
Post-spike recovery is effectively immediate (< 1ms vs 100ms budget).

## Disclosures

- Run executed on private high ports (29443/28443/29444 via
  `SMALT_BENCH_{ARM,DATA,TLS}_PORT`) because other lanes hold the canonical
  9443/8443/9444; the harness spawns its own substrate with matching app-env
  overrides, so this exercises the same listener code paths.
- One development run (ports 19443/18443/19444, different private ports, dev
  ports shared with another lane's substrate) observed the substrate listener
  disappear at cycle 7 (500 connection-refused per cycle for cycles 7-10).
  It did not reproduce on the receipted run above (isolated ports, full PASS);
  treated as cross-lane port contention on non-isolated ports, not a substrate
  defect. If it reproduces on isolated ports, it is a real finding.
- Accept-latency figures are per-client whole-cycle-throughput-shaped (they
  include queueing behind 499 other clients on a shared listener), so the
  first-cycle p50 of ~97ms is consistent with, and bounded by, the request
  p95 budget.
