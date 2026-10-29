# Receipt — v26.10.25 wrap census (coordinator, 2026-10-25)

Standing: **PARTIAL_ALIVE → greens landed during wrap** — the census classified
the whole uncommitted Oct 23–25 wave (100 dirty entries: 34 modified tracked,
66 untracked ~13.3k LOC) and every red got a fix lane. Context: solo.

## Census output (real)

```
mix test (asdf 1.20.4-otp-29 / erlang 29.1.2, offline self-boot)
Result: 1230/1250 passed, 5 invalid, 7 skipped, 12 excluded   <- run 1 (census)
Result: 1257/1262 passed, 12 excluded                          <- run 2 (post-fix re-run)
Failed: 20 tests -> 5 -> (ja10 fixed; remaining 4 pass in isolation)
```

Run-2 residue (all four green in isolation, order/interference class —
the court-x2 shifted-failure-set law governs the release window):
ja10 leg 4 telemetry plug-allowlist (FIXED: the latency lane's ARM
LatencyPlug mount legitimately changed the metadata; allowlist admits the
wrapper), kafka seal/restart + produce (interference), event_grid bridge
already_started (async leak class, F8 precedent), bkcells ARD P99 ratio
fence (perf noise; passed census run 1).

## Failure attribution → fix lanes (all mechanical, by test file → lane map)

| # | Court | Class | Fix (receipt evidence below) |
|---|---|---|---|
| 1–3 | TraceSessionCourtTest ×3 | arming matched 0 clauses when `Smalt.EgressRouter` not yet loaded | `ensure_loaded` before arming (arm/2 + TRACEBUG inline arm) — court 3/3 after fix |
| 4–8 | InternalTier.CensusTest ×5 | population fence: 6 files on disk unregistered; kdlith_w2 client/status tokens; module allowlist | registration + typed exemptions (kds3_s4 twin precedent) + allowlist; `hang_reap.exs` sleep → observation-paced triple-confirm (no `Process.sleep` anywhere — operator direction 2026-10-25); census file rerun **exit 0** |
| 9, 10, 12, 13, 15, 16 | amqp10 RST, eplaw/expl11r3 subprocess boots, kafka wire, spof3 | load-flake class (60s subprocess-boot timeouts under load 15–17; moving failure sets across runs 4→3→4) | no code fix owed; re-proven in the Wave-4 quiesce window (court-x2 two-greens law) |
| 11 | ja10 transparency | load-flake class | same |
| 14 | ArmstrongIdiomCourt atom fence | first-call lazy-load noise, NOT minting (traced: zero binary_to_atom/list_to_atom calls on a warm call; warm delta = 0) | warm-then-measure fence (same shape as vm_zero_growth); court **8/8** after fix |
| 17 | Ath3LawCourt | env: wasi staging toolchain deleted by disk cleanup (graphlaw_wasm.wasm + graphlaw-run release binary missing; verify mode = 14 FAILs) | pinned `priv/graphlaw.wasm` (58,124,612 B, new-EH re-pin) copied to `target/wasm-abi/wasm32-wasip1/wasm/`; runner repointed graphlaw-run → **graphlaw-run-eh** (graphlaw's sole packet-4 stdio runner after the wasmi retirement) in 3 smalt courts; binary rebuilt from graphlaw HEAD |
| 18–20 | SignInsLogTest ×3 | `/v1.0/*` missing from the tenant-fence reserved segments → foreign-tid account namespacing → GraphRoutes fallthrough → blob 400 | `v1.0` added to `@reserved_first_segments` + `blob_plane_path?/1`; court **3/3** after fix; live-substrate probe reproduced (blob 400 on 8443) pre-fix |

## Embodied evidence (commands + results, this session)

```
scripts/fast_test.sh test/internal/internal_tier_census_test.exs   → exit 0
mix test test/integration/signins_log_test.exs                      → Result: 3 passed
mix test test/internal/armstrong_idiom_court_test.exs               → Result: 8 passed
mix test test/integration/trace_session_court_test.exs               → Result: 3 passed
  (first run after the arm fix: 2 passed / 1 inline-arm residue; dedup fix disclosed)
```

## Disclosure

Coordinator edits rode lane-owned files under the compile-freeze SLA, named
per-lane in `_LANES.md` + `RESOLUTIONS.md`: census-fence registration,
hang_reap sleep removal, armstrong warm-up, trace-court arms, the v1.0
reserved-segment fix (`lib/smalt/egress_router.ex` — shared seam), and the
graphlaw-runner repoint (3 tracked test files). No lane build roots were
created by the coordinator (fast_test per-hash roots only; `just lane-clean`
scheduled before the final commit).
