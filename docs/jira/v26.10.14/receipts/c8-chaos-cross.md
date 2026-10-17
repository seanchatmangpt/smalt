# Receipt: C-8 cross-product chaos overlay (composite stress)

- Date: 2026-10-16 04:07-04:12 PDT (run 2; run 1 at 03:55-04:00)
- Lane: C-8 (chaos overlay DURING cross-product load), v26.10.14 bench wave
- Repo: `/Users/sac/smalt`, branch main, darwin/arm64, OTP 28.3.1 / Elixir 1.19.5
- Scripts (owned by this lane):
  - `scripts/bench/c8_chaos_cross.mjs` — 3-surface sustained load driver (blob
    put 8 KiB unique-name-per-put, cosmos point-read of 200 seeded docs with
    self-healing re-provision, EH send 1 KiB with producer recreate on failure)
  - `scripts/bench/c8_chaos_overlay.sh` — kill orchestrator: boots the
    substrate on the c8 block 39080..39085 (mirrors lib.sh `bench_boot` but also
    pins `:sb_shared_key`, which lib.sh leaves nil and EH CBS SAS requires —
    same fix b4 made), starts the driver, SIGKILLs the substrate BEAM at
    t=60s (uniform traffic) and t=180s (cosmos-emphasized traffic since t=120s,
    5x cosmos pacing, blob/eh at ~1/6 rate), re-boots after each kill,
    tears down at t=270s. A 1 Hz port-watch sampler recorded
    out-of-lane listeners on the c8 block; **0 squat markers in run 2**.
- Events (46,442 in run 1 / ~47k in run 2):
  `docs/jira/v26.10.14/bench/c8-chaos-cross.jsonl` — per-op
  `{ts,surface,ok,latency_ms,err}` plus `{kind:kill|reboot_done|portsquat}` markers.
- Chaos method: SIGKILL of the whole substrate BEAM (B-11's class). Per-process
  kill of the ARM Bandit listener is unreachable from outside the BEAM, so the
  full-restart class is the honest option producing client-visible errors on
  every surface sharing the VM. Reboot-to-LISTEN: 2700 ms (p1) / 2718 ms (p2),
  consistent with B-11's 4.5-4.8 s full-gate reboot (this run gates on ARM TCP
  listen only).
- No commits, no lib edits.

## Per-surface recovery table (run 2)

| kill | surface | dead-window errors (kill+30s) | TTFS after kill | post-recovery p50 |
|---|---|---|---|---|
| p1 (uniform, t=60s) | blob | 1 | 2024 ms | 1.0 ms |
| p1 | cosmos | 526 | 2038 ms | 1.0 ms |
| p1 | eh | 526 | 1928 ms | 0.0 ms |
| p2 (cosmos-emphasized, t=180s) | blob | 0 | 12892 ms | 1.0 ms |
| p2 | cosmos | 899 | 2284 ms | 0.0 ms |
| p2 | eh | 7 | 2355 ms | 1.0 ms |

TTFS per surface = first successful op after the kill epoch. All surfaces
recovered at or just before ARM LISTEN (+2.7 s reboot), i.e. TTFS ≈ reboot time
with no per-surface recovery lag beyond reconnect. p2 blob TTFS 12.9 s is a
driver artifact, not substrate lag: the blob worker was wedged inside one
long SDK-retried upload that spanned the kill (only 1 op in the 10 s before
the kill), then succeeded on its next attempt.

## Verdict vs B-11 baselines (TTFS 2.77-2.98 s, reboot 4.5-4.8 s)

- **COMPARABLE.** Per-surface TTFS 1.9-2.4 s (p2 blob's 12.9 s is driver-side,
  disclosed above) vs B-11's 2.77-2.98 s single-surface TTFS; reboot faster
  because the C-8 gate is ARM-LISTEN only (B-11 gated on a full auth canary).
- **Cross-surface blast radius: total, as designed.** Killing the substrate
  BEAM errors every surface on the VM together — cosmos and EH immediately
  (hundreds of refusals each), blob almost never client-visibly because the
  Azure blob SDK's default retry policy absorbs a 2.7 s outage entirely
  (1-3 surfaced errors across both kills; default-configured SDKs mask
  chaos; the raw refusals are in the jsonl).

## Finding: out-of-chaos new-connection refusal windows (NOT chaos-caused)

Both runs showed recurring ~20-30 s windows in which NEW connections to
egress 39081 (cosmos per-op connections) and EH 39083 (producer reconnects)
get ECONNREFUSED while already-established connections (blob keep-alive puts
at 1 ms p50) keep working — cyclical, starting ~t+41 s in both runs, **before
the first kill**, and recurring after recoveries. Run 2's 1 Hz port sampler
recorded **zero foreign listeners** on 39080..39085, ruling out a port
squatter; the substrate log shows requests served normally throughout.
Signature: fresh-connect refusals only, correlated across surfaces, ~60 s
cycle. Most consistent with accept-side saturation (backlog overflow under
composite load) cycling with load; mechanism NOT diagnosed to root cause —
flagged as a substrate stability finding for a follow-up lane
(single-surface load did not produce it in B-2/B-3/B-4).

Composite-stress context: under the emphasis phase the refusal windows make
"post-kill TTFS" partially confounded (p2 cosmos 899 errors include a window
that began ~26 s after recovery); the TTFS numbers above are first-success
after kill and are honest about that.

## Harness fixes disclosed (scripts only)

1. `:sb_shared_key` pinned at boot (lib.sh `bench_boot` leaves it nil; EH CBS
   SAS fails with INVALID_LOCAL_SAS — same fix b4 applied).
2. Blob driver: unique name per put — the substrate correctly refuses re-put
   of an existing blob name (WORM immutability, run-1 first evidence:
   "Blob modification refused: container policy enforces immutable WORM
   retention").
3. Blob/cosmos workers self-heal after restart (in-memory store is wiped by
   SIGKILL: run 1 saw ContainerNotFound + 404 point-reads until
   re-provisioning was added).

## See Also

`docs/jira/v26.10.14/bench/c8-chaos-cross.jsonl` ·
`docs/jira/v26.10.14/receipts/bench-11-chaos-tls.md` (single-surface baseline) ·
`scripts/stress/chaos_kill.py`
