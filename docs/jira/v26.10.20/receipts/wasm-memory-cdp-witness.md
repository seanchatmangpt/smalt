# W14-E — Popcorn wasm worker memory via CDP (S9 close)

Date: 2026-10-20
Lane: W14-E (substrate-op, measurement)
Subject: popcorn_demo in-browser BEAM (public/out/worker.mjs → beam.wasm), headless Chromium (chrome-headless-shell 156.0.8078.4, chromium_headless_shell-1248), substrate UP throughout (9443/9444/5672/5673; pid 54136 → 9849 mid-session, not restarted by this lane)
**Standing:** **PARTIAL_ALIVE → REFUTED vs budget** (measurement landed; the 32 MB ceiling is breached at the allocation surface)

## Method (no repo file edits)

S9's close condition was "CDP Performance.getMetrics on the worker target OR Module.wasmMemory exposure". Both routes were attempted:

1. **Raw CDP** (`/tmp/w14e_cdp*.mjs`, node global WebSocket, chrome-headless-shell `--remote-debugging-port=0`): page target fully scriptable (`Runtime.evaluate`, `Performance.getMetrics` on the page: JSHeapUsedSize 1.6–1.75 MB — wasm memory is not in the JS heap). Worker targets appear (9 per run, type `worker`) and attach, but `Performance.enable` and even trivial `Runtime.evaluate` on dedicated-worker CDP sessions time out in this Chrome — **the worker CDP surface is attached-but-inert**. This is why S9 read UNMEASURABLE.
2. **Close condition satisfied via Module.wasmMemory exposure**: ran the app from a /tmp copy of `public/` (`/tmp/w14e-pub-c1792561826`) with a measurement beacon patched after `const module = await createModule(moduleConfig);` in `out/worker.mjs` (SHIM-COURT-style: real boot, real smoke legs, real substrate, no mocks). The beacon reads `module.wasmMemory` and beacons `fetch("/w14e-beacon", ...)` to the probe's own server; page `#status` must reach `live=` before any sample counts.

## Result (3 runs, each: boot sample + 15/30/60 s post-boot)

| run | phase | wasmMemory.buffer.byteLength | vs 32 MB (33,554,432 B) budget |
|---|---|---|---|
| 1 | boot / +15s / +30s / +60s | 67,108,864 B (64 MiB) every phase | REFUTED (2.0x) |
| 2 | boot / +15s / +30s / +60s | 67,108,864 B (64 MiB) every phase | REFUTED (2.0x) |
| 3 | boot / +15s / +30s / +60s | 67,108,864 B (64 MiB) every phase | REFUTED (2.0x) |

All 12 samples across 3 runs: exactly **67,108,864 bytes**, zero drift boot→+60s.

Corroboration (OS level, one run): the renderer hosting the worker at RSS 328.7 → 342.7 MiB between post-settle samples (+5 s apart), consistent with a large committed region; page JS heap is ~1.7 MB, so the memory is wasm-side.

## Interpretation (honest boundary)

- What is measured: the exposed `WebAssembly.Memory` allocation — `module.wasmMemory` is an own property of the emscripten module; `wasmMemory.buffer.byteLength = 67,108,864` from boot and it never shrinks in the observation window. This confirms the static reading in `BENCH_SCVD.md` S9 lane (`beam.mjs`/worker.mjs `initial: 1024 pages` = 64 MiB initial).
- What remains unmeasured: the strictly-physical-commit figure. `Performance.enable`/`Performance.getMetrics` is unsupported on dedicated-worker CDP sessions in this Chrome, and `performance.measureUserAgentSpecificMemory` is absent even under crossOriginIsolated=true; so a per-target committed-heap breakdown has no exposed API. byteLength on a shared growable WebAssembly.Memory reports allocated pages (64 MiB initial), which is the ceiling the PRD budget binds against.
- Verdict: **REFUTED** against the 32 MB ceiling at the allocation surface (64 MiB = 2.0x budget, stable, all runs). S9's "binding surface UNMEASURABLE" is closed: it is measurable via in-worker Module.wasmMemory exposure; the number refutes the budget.
- Close condition met for the exposure route; the CDP worker-target route stays inert (Chrome limitation, not smalt).

## Probe artifacts (scratch, /tmp only)

- `/tmp/w14e_cdp5.mjs` (driver), `/tmp/w14e_patch_final.cjs` + `/tmp/w14e_patch4.cjs` (instrumentation patches), `/tmp/w14e_rss.mjs` (RSS corroboration), `/tmp/w14e-pub-c1792561826/` (instrumented copy of public/)
- Repo diff: none. Probe browsers cleaned up after runs.

## Replay

```
D=$(cat /tmp/w14e_pubdir)  # /tmp/w14e-pub-c1792561826
cp -R /Users/sac/smalt/popcorn_demo/public $D   # if missing, re-copy + node /tmp/w14e_patch_final.cjs $D && node /tmp/w14e_patch4.cjs $D
RUN=1 node /tmp/w14e_cdp5.mjs   # needs substrate up; SMOKE_RECEIPT live= must settle first
```

## RE-WITNESS addendum — 2026-10-22 (lane BK-REWIT3): replay materials UNAVAILABLE

The probe artifacts were /tmp scratch, now deleted: `/tmp/w14e_cdp5.mjs`,
`/tmp/w14e_patch_final.cjs` + `/tmp/w14e_patch4.cjs`, and the instrumented
public copy `/tmp/w14e-pub-c1792561826/` — all MISSING (exit=1 checks
2026-10-22). The replay requires re-patching a copy of `popcorn_demo/public`
with the measurement beacon and re-running chrome-headless-shell with the
substrate up — re-authorable but not replayable verbatim. Typed:
SUSPECT-PERMANENT-with-owner → **substrate-op** measurement lane (re-author
probe per the receipt's Replay section).
