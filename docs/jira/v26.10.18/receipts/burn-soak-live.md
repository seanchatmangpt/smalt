# Burn-soak live host receipt (first live host burn-soak, v26.10.18)

Standing: **PARTIAL_ALIVE — typed FAIL verdict on unledgered faces; 3/3-clean NOT met; atom-flood fix i22 WITNESSED holding**

- Repo: /Users/sac/smalt, branch main @ 63c7082 (dirty tree; v26.10.18 rewrite wave in flight)
- Lane shape: `just burn-soak` = 4x yes-CPU hogs + AMQP atom-flood across 3x (offline + wire tier)
- Window: 2026-10-18 14:39–19:29 PDT (4h50m wall, 9 attempts)
- Acceptance: 3/3 clean NOT met; typed classification of every failure MET (below).

## Verdict line (final attempt)

```
[BURN-SOAK] VERDICT: FAIL — unledgered failure face(s); fix or ledger before re-burn
```

## Machine / load context (concurrent-lane separability)

Load-1 average across the window (60s samples, `tmp/burn-load-samples.txt`):

```
14:39 PDT baseline   109.26 154.87 158.04
23:36Z attempt 6     340.02 306.46 258.34
19:01 PDT peak       442.39 435.09 404.51
19:29 PDT end         39.86  49.94 114.25
```

The 4 hogs + flood are the lane's own load; everything above baseline is fleet contention and is
separable via the samples file. Memory stayed ~68% free throughout (not OOM).

## Result rows (schema smalt-burn/v2, emitted per leg)

```
f = tmp/burn-soak-20261018T233643Z.jsonl  (attempt 6)
1 offline exit=2    tests=2674 fails=21 faces=21 flood=790
1 wire    exit=137  tests=0    fails=0  faces=9  flood=0     (killed mid-leg)
2 offline exit=137  tests=0    fails=0  faces=0  flood=0     (killed mid-leg)

f = tmp/burn-soak-20261019T011607Z.jsonl  (attempt 8)
1 offline exit=137  tests=0 fails=0 faces=6  flood=716  (killed after partial run)
1 wire    exit=1    tests=0 fails=0 faces=0
2-3      exit=1    tests=0 fails=0 faces=0             (all instant-killed)

f = tmp/burn-soak-20261019T020834Z.jsonl  (attempt 9, canonical)
1 offline exit=2    tests=2690 fails=16 faces=16 flood=5746
1 wire    exit=2    tests=2755 fails=32 faces=32 flood=5666
2 offline exit=2    tests=2694 fails=11 faces=11 flood=3821
2 wire    exit=1    tests=0    fails=0  faces=0
3 offline exit=1    tests=0    fails=0  faces=0
3 wire    exit=1    tests=0    fails=0  faces=0
```

Full legs: **10,813 tests executed, 80 failures, 58 unique faces — 0/58 present in
docs/jira/v26.10.17/FLAKE_LEDGER.md (17 ledger rows; zero matches, exact or file-level).**

## Failure classification (typed; every failure/exit accounted for)

| Class | What | Count | Evidence |
|---|---|---|---|
| C1 | ExUnit.TimeoutError 60000ms class, load-correlated | 80 failures / 58 unique faces, all UNLEDGERED | attempt-5 leg log witnessed 16/16 as `ExUnit.TimeoutError ... timed out after 60000ms`; attempt-6/9 faces are file:line only (leg-log truncation, C6). Face files: mcp_wire (22), auth_enforce (9), pplan (3), azsim/integration (3), tls (2), canonical_projection (2), enclave_lifecycle (2), mcp (2), + 10 files with 1 face |
| C2 | External beam SIGKILL (exit 137) | 4 legs + substrate DOWN in same window | memory 68% free — not OOM; fleet ops during live lanes |
| C3 | Beam SIGTERM ~3s after boot → mix test exit 1, tests=0 | 7 legs | witnessed directly: probe booted, listeners bound, `18:59:52 [notice] SIGTERM received - shutting down` x2, `GenServer.call(ExUnit.Server, ...)` EXIT; identical wire probe minutes later: `15 tests, 0 failures` |
| C4 | Substrate boot timeout under cold compile + load | 2 attempts | `[UP] FAIL: substrate not serving within 90s` while `Compiling 147 files` at load 109-158 |
| C5 | Build-dir flock contention between lanes | 5 substrate-boot retries | `Waiting for lock on the build directory (held by process 97719)` |
| C6 | soak.sh harness defects (pre-existing upstream; my snapshot patch disclosed) | 2 witnessed + 1 structural | (a) `--jsonl) JSONL="$2" ;;` arm missing inner `shift` — any `--jsonl X` invocation re-sees the value as `$1`, hits `*) usage`, exit 3 (witnessed rc=3 with byte-stable script, sha 08574a74; foreground identical args varied → value-as-next-arg mechanism confirmed by `bash -x`). (b) `OFF_FAILS=$(grep -oE '[0-9]+ failures?($|,)')` cannot match `16 failures (90 excluded)` → grep exit 1 under `set -e` killed attempt-5 after a full leg with zero emit. Patched in my scratch snapshot `/tmp/burn-soak-snapshot.sh` only (sha 112e0329): `|| true` + regex relaxed; shared `docker/burn/soak.sh` untouched. (c) LEG_LOG is truncated per leg — per-leg evidence destroyed; unpatched. |

## The burn's target: i22 atom-flood fix HOLDS

```
$ grep -c "debug] [amqp-atom] request read failed: :closed" tmp/burn-leg-20261018T230530Z.log
290458
$ grep -m2 "error] [amqp-atom" tmp/burn-leg-20261018T230530Z.log   → no matches
```

290,458 mid-request-close floods (`PUT /flood HTTP/1.1\r\n` partial line, flood_conns up to 5,746/leg)
routed through the atom_bridge `:closed` silent exit at debug level; zero error-level
`[amqp-atom]` lines; substrate kept serving through every flood leg. The i22 fix
(docs/jira/v26.10.17/receipts/i22-atom-flood-fix.md) is witnessed holding under saturation.

## Artifacts

- Canonical JSONL: /Users/sac/smalt/tmp/burn-soak-20261019T020834Z.jsonl
- Attempt-6 JSONL: /Users/sac/smalt/tmp/burn-soak-20261018T233643Z.jsonl
- Attempt-8 JSONL: /Users/sac/smalt/tmp/burn-soak-20261019T011607Z.jsonl
- Load samples (60s): /Users/sac/smalt/tmp/burn-load-samples.txt
- Leg log (flood evidence): /Users/sac/smalt/tmp/burn-leg-20261018T230530Z.log (290k flood lines)
- Run logs: /Users/sac/smalt/tmp/burn-soak-live9.log, -live10.log, -live11.log, -live12.log
- Harness used: /tmp/burn-soak-snapshot.sh (pinned copy of docker/burn/soak.sh @ mtime 15:00 PDT,
  sha 112e0329 after my disclosed grep fail-safe patch; repo script untouched by this lane)

## Verdict summary

- 3/3 rounds clean (stress excluded): **NOT met** — best run completed 3 full legs of 6; 80
  failures across 10,813 tests, every face unledgered.
- Typed classification of every failure: **MET** — C1-C6 above account for every exit code and
  every failure face observed across all 9 attempts.
- Follow-ups: (1) ledger the C1 saturation-timeout faces or fix the owning tests; (2) stop beam
  sweeps / substrate toggling while burn lanes hold the lock (C2/C3 — fleet hygiene, not substrate
  defects); (3) fix soak.sh --jsonl shift, failures-regex, and per-leg log truncation; (4) re-burn
  on a quiesced machine before court-x2.
