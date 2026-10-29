# t45 BOOTPROF — NFR-FOOTPRINT boot-phase profile

Context: solo

- **Lane**: t45 (BOOTPROF, bench-runner)
- **Date**: 2026-10-21
**Standing**: PARTIAL_ALIVE (profile is real and receipted; ETS-trace channel silent — noted below)
- **Result file**: `/Users/sac/smalt/tmp/bench/t45-boot-phases.jsonl` (6 valid rows: 1 cold, 5 warm; 2 earlier rows dropped as VOID — stale epoch-scale `wall_to_eval_enter_ms` from a prior instrumentation revision)
- **Lane scripts**: `/Users/sac/smalt/scripts/bench/t45_boot_phases.sh`, `/Users/sac/smalt/tmp/bench/t45_boot_eval.exs`
- **Ports**: 39940..39945 (private band). 39920..39935 held by other lanes' beams (pid 44082 `tmp/tls13_boot.exs` + two more blocks) — pre-flight refused per port law, lane relocated, no eviction.

## Machine

```
$ bench-machine-spec
{"cpu":"Apple M3 Max","cores":"16","ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

(embedded `machine` field in every jsonl row: Apple M3 Max, 16 cores, 48 GB, Elixir 1.19.5, OTP 28, Darwin 26.2)

## Command (replay)

```
bash scripts/bench/t45_boot_phases.sh 4   # boots sequential private-port substrates, 39940..39945
```

Driver spawns `MIX_ENV=test MIX_BUILD_ROOT=_build-t45 mix run --no-start tmp/bench/t45_boot_eval.exs`
with lock fd closed (`9>&-`); the in-VM eval installs a `:logger` handler stamping every log
event with VM-uptime ms, times each dep app's `Application.ensure_all_started/1` with
`:timer.tc`, polls the 5 expected ports in-VM, writes `tmp/bench/t45-vm-stamps.json`, `:init.stop()`.

## Warm steady-state breakdown (5 warm boots; cold boot 1 = 7.6 s wall incl. compile)

| phase | range (warm) | share |
|---|---|---|
| mix/BEAM pre-eval (fork → eval entered; mix.exs/deps config eval, code load) | 1250–2445 ms | dominant |
| in-VM app start total (eval → all 6 listeners accepting) | 396–493 ms | ~15% |
| ↳ `:smalt` app itself | 268–314 ms | |
| ↳ `:ash` 43–72 · `:joken` 36–62 · `:ash_ex4pm` 24–38 · `:bandit` 7–14 ms | | |
| post-ready teardown (`:init.stop()` → process exit; NOT part of readiness) | ~1080–1115 ms | excluded from boot-to-ready |

In-app listener ordering (uptime-relative stamps, last boot):
egress 2332 → ARM 2364 → TLS twin 2429 → AMQP sb 2504 → AMQP eh 2504 → MCP 2516 ms,
i.e. listener fan-out spreads ~185 ms inside the smalt app's ~310 ms; the TLS twin leg
(+65 ms after ARM) carries the dev-cert load (cert cache warm by mtime — cold first-boot
cert generation is a one-time cost, seen in the 7.6 s cold row).

## Top-3 phase costs (where the ~2.0 s T36 boot lives)

1. **Mix/BEAM pre-eval, ~1.25–2.45 s** — `mix run` re-evaluates mix.exs + all dep configs
   and walks compile manifests before user eval runs. This alone exceeds the 500 ms
   aspiration 2.5–5x.
2. **`:smalt` app start ~270–315 ms** — supervisor tree + 6 listeners (egress/ARM/TLS/AMQP/MCP).
3. **Heavy dep apps ~105–170 ms combined** — ash, joken, ash_ex4pm (joken alone 36–62 ms for
   JOSE compile/load).

## Proposals toward 500 ms (NOT implemented — dispatch decisions)

1. **Prebuilt release boot** (`mix release` + `bin/smalt start` or a precompiled boot
   script): eliminates mix.exs/deps-config re-eval and manifest walks — est. **−800 to
   −1500 ms** (largest cut; attacks the dominant phase directly).
2. **Phased listener start** (ARM/egress front door first, defer AMQP/EH/MCP/TLS-twin to a
   `start_phase` or a deferred supervisor child spec): readiness = front door accepting at
   ~+290 ms in-VM instead of waiting for the full ~185 ms listener fan-out — est.
   **−150 to −200 ms** on boot-to-first-request.
3. (honorable mention) Lazy joken/STS init on first auth request: est. **−40 to −60 ms**.

Even proposal 1+2 combined lands ~1.3–1.7 s wall to first-request on `mix run`; 500 ms
aspiration is reachable only with release boot (P1) plus P2.

## Limitations (honest)

- ETS-creation trace channel was silent on all runs (dbg tracer captured 0 tables) —
  ETS cost is therefore NOT attributed; the `init got unexpected ETS-TRANSFER
  :smalt_monitor_metrics` log line shows table transfers at ~+320 ms but per-table cost is
  unmeasured.
- `first_listener_ms_since_eval` field changed scale mid-series (monotonic → uptime base);
  only `wall_total_ms`, `wall_to_eval_enter_ms`, `total_ms_since_eval_enter` are
  comparable across all 6 rows.
- Wall numbers carry cross-lane machine noise (3 other substrate beams were listening
  during the run).

## Reproduction (2026-10-21 backfill)

Fresh re-run skipped (replay = 6 sequential private-substrate boots — not a cheap replay).
Output lives in the cited artifact `tmp/bench/t45-boot-phases.jsonl`; integrity re-checked:

```text
$ python3 -c "import json; rows=[json.loads(l) for l in open('/Users/sac/smalt/tmp/bench/t45-boot-phases.jsonl')]; print('rows:',len(rows))"
rows: 6
exit 0
```
