# APEX-4B — telemetry emit/collect bench (fresh lane)

**Standing:** **ALIVE** (clean run landed; 4-subscription fan-out shape BLOCKED by a typed broker defect, disclosed below)

## What ran

- Module: `popcorn_demo/lib/popcorn_demo/apex_fanout.ex` — compiles clean
  (`MIX_BUILD_ROOT=_build-apex4 mix compile`, exit 0; only pre-existing
  transport.ex type warnings). Not benched: the 4-subscription filtered
  fan-out drain is blocked by a typed broker-side defect (below).
- Fallback minimal shape (task-sanctioned): `popcorn_demo/lib/popcorn_demo/apex4_telem.ex`
  — 256-event telemetry emit/collect over a lane-private substrate
  (`popcorn_demo/bench/apex4_run.sh`, ports 39950-39955, per-run key,
  lock fd closed, port preflight with refuse-don't-evict).

## Measured (one clean run, 256 events, queue entity)

Command: `APEX4_DEBUG= bash popcorn_demo/bench/apex4_run.sh` (exit 0)

```
apex4=OK(events:256,pub_eps:2.56e5,publish_ms:1,collect_eps:5127.7,drain_ms:49.925,lag_p50_ms:18,lag_p95_ms:46,lag_max_ms:50,loss:0)
{"machine": "darwin-aarch64-apple-darwin25.2.0", "op": "emit_collect", "errors": 0, "n": 256, "topic": "apex4-t-1792611029851-254157", ...}
```

Result row (popcorn_demo/bench/apex4-telemetry.jsonl, single clean row):

```json
{"machine": "darwin-aarch64-apple-darwin25.2.0", "op": "emit_collect", "errors": 0, "n": 256, "topic": "apex4-t-1792611029851-254157", "publish_eps": 256000.0, "loss": 0, "drain_ms": 49.925, "publish_ms": 1, "lane": "apex4-telemetry", "surface": "sb-queue-telemetry", "events_per_sec": 5127.7, "collect_lag_p50_ms": 18, "collect_lag_p95_ms": 46, "collect_lag_max_ms": 50}
```

Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Disclosed defects (typed, evidence-cited)

1. **UNAUTHORIZED_ENTITY detach on `sb_endpoint` mismatch** — a lane substrate
   that boots without pinning `Application.put_env(:smalt, :sb_endpoint, ...)`
   lets `SasVerifier.endpoint/0` fall back to the default endpoint, so CBS
   claim audiences (`sb://127.0.0.1:39xxx/...`) never match and every
   queue-receiver attach gets `amqp:unauthorized-access/UNAUTHORIZED_ENTITY`
   detach + `transfer on unknown handle` connection close (witnessed across
   6+ runs, both shared and lane-private substrates; decode of the detach list
   bytes `52015601...554E415554484F52495A4544454E54495459` = "UNAUTHORIZED_ENTITY").
   Fix on the lane side: pin `:sb_endpoint` at boot (in apex4_run.sh + the
   b91-style boot EVALs). Possible KD row: boot-contract gap.
   "transfer on unknown handle 0" close frame decoded from `C03503...756E6B6E6F776E2068616E646C652030`.
2. **4-subscription ApexFanout drain detach** — same class, NOT resolved:
   on the corrected boot the fan-out drain still got a clean-looking detach
   (empty payload; error lives in the list, not payload — first traces were
   blind to it). NOT retested after the sb_endpoint fix — the fan-out shape
   mints put-tokens for topic + subs + DLQ audiences; the sb_endpoint fix
   plausibly closes it too but is UNTESTED. UNVERIFIED.
3. **Shared-tree compile freezes (2x)** — concurrent lanes' transient
   untracked `lib/smalt/powl2/` rewrites and a `connection.ex` syntax error
   broke shared compile mid-boot twice; resolved by bounded poll-for-green
   (compile-freeze SLA held — no lane cross-edits).

## Lane hygiene

- Result file: popcorn_demo/bench/apex4-telemetry.jsonl (lane writes ONLY this file)
- Driver: popcorn_demo/bench/apex4_run.sh; substrate logs per-attempt in popcorn_demo/bench/out/apex4-substrate-*.log
- Diag env-gated traces (APEX4_DEBUG / APEX4_NOSETTLE) left in apex4_telem.ex / apex_fanout.ex (drain_refused trace) — env-gated no-ops in bench mode.
- Lane build roots NOT deleted (coordinator integration law): `_build-apex4` (popcorn_demo), `_build-laneapex4` (smalt).

## Falsifier

Rerun `bash popcorn_demo/bench/apex4_run.sh` — exit 0 with a `loss:0` row is the
pass contract; the earlier UNAUTHORIZED_ENTITY failures are the vacuity
contrast.
