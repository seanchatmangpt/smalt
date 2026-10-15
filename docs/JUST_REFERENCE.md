# Just Reference

Complete ops surface for the smalt repository via `just`. Every recipe is
self-documenting: `just --list` shows descriptions. Canonical checkout:
`~/smalt`.

Entry point: `just` (no args) runs `court` — the full admission gate.

## Recipes

| Recipe | What it runs | Exit-code contract | Typical latency |
|---|---|---|---|
| `default` | Alias for `court` | same as `court` | see `court` |
| `doctor` | `python3 scripts/doctor.py` — runtime preflight (deps, ports, certs, toolchain) | 0 healthy / 1 finding | ~2s |
| `status` | Inline: smalt beams (pgrep), listening ports 9443/9444/5672/5673 (lsof), 5 newest `tmp/*receipt*.json` summaries | 0 always (report-only; safe with no substrate) | ~1s |
| `logs` | `tail -f` newest `tmp/*.log` | 0 while following / 1 if no logs exist | follows |
| `receipts` | `ls -lt tmp/*receipt*.json \| head -15` | 0 always | <1s |
| `up` | `mix run --no-halt` (pid written to `/tmp/smalt.pid`) | 0 while running; Ctrl-C stops | blocking |
| `down` | `kill $(cat /tmp/smalt.pid)`, removes pid file | 0 always (idempotent) | <1s |
| `clean` | Kill stray smalt beams (beam.smp matching "smalt"), `rm -rf _build-lane*`, `rm erl_crash.dump tmp/*.log` | 0 always; never touches `_build/` or `deps/` | ~1s |
| `gen` | `mix smalt.gen` | 0 on success | seconds |
| `test-offline` | `mix test` (T1) | 0 pass / nonzero fail | 1-3m |
| `test-wire` | `mix test test/wire` (T2) | 0 pass / nonzero fail | 1-3m |
| `test-sdk-smoke` | `node test/sdk-smoke/run.mjs` (T3) | 0 pass / 1 probe fail / 2 substrate never up / 3 harness failure | ~1m |
| `eh-smoke` | `node test/sdk-smoke/eh-run.mjs` (Event Hubs lane; boots own substrate) | 0 pass / 1 probe fail / 2 substrate never up / 3 harness failure | ~1m |
| `census` | `bash scripts/sb_census_replay.sh` (Service Bus 8-probe census, real SDK) | 0 all pass / 1 census fail / 2 substrate never up / 3 harness failure | ~1-2m |
| `mutation-court` | `python3 scripts/mutation_court.py` (validator-gate non-vacuity proof) | 0 non-vacuous / 1 vacuous / 2 BLOCKED (compile broken) | ~3-5m |
| `tf-plan-smoke` | `bash scripts/tf_smoke.sh` (T4, terraform fixture plan) | 0 pass / 1 preflight or substrate failure / 2 terraform step failure / 77 SKIPPED-NETWORK (registry unreachable; court fails — rerun online) | <1m |
| `bench` | `python3 scripts/bench.py` (boots substrate; writes `tmp/bench-receipt.json`; fixed ports 9443/8443/5672 — if they are held, set `SMALT_BENCH_{ARM,DATA,AMQP}_PORT` to a port from the documented private range 39000-39999 (docs/DEV_LOOP.md "Private port allocation") or let bench auto-pick an ephemeral block; same functions, same receipt schema, chosen ports recorded in the receipt. Exit contract: 0 only when all 5 CTQ verdicts PASS; any FAIL → typed `GATE: FAIL (…)` + exit 1) | 0 complete + 5/5 CTQs / nonzero fail | 2-5m |
| `bench-check` | `python3 scripts/bench_check.py` (CTQ gate over `tmp/bench-receipt.json`) | 0 all CTQs pass / 1 missing/stale/failing receipt | ~1s |
| `soak` | `python3 scripts/stress/soak.py` (25 min mixed traffic at 50 rps) | 0 pass / nonzero on any 5xx, RSS growth >20% after min 5, or error | ~25m |
| `spike` | `python3 scripts/stress/spike.py` (500-concurrent spike, recovery, TLS herd) | 0 pass / nonzero fail | 5-10m |
| `tls-churn` | `python3 scripts/stress/tls_churn.py` (handshake churn vs 9444 TLS twin) | 0 pass / nonzero if any scenario cannot complete | 2-5m |
| `court` | `doctor test-offline test-wire test-sdk-smoke tf-plan-smoke bench-check` | 0 only when every court passes | ~5-15m |
| `gate` | Alias for `court` (legacy name, kept for compat) | same as `court` | see `court` |

## Conventions

- Every wrapper recipe invokes the landed script; no logic is duplicated here.
- Exit codes of wrapped scripts pass through unchanged.
- `status`, `receipts`, `clean`, `down` are safe to run with no substrate.
- Stress recipes (`soak`, `spike`, `tls-churn`, `bench`, `mutation-court`)
  boot and kill their own substrates — do not run two concurrently (port
  contention on 9443/9444/5672/5673).
