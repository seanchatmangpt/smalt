# 05 — Per-Component Watch Agents ("Superfans") During Waves

**Wave:** v26.10.15 · **Lane:** 05 · **Status:** PLANNED

## Summary

The 27-minute leaked-lock incident is a **detection-latency defect**, not an engineering defect: the orphan condition was mechanically detectable the moment the parent exited (the detector already exists in `scripts/substrate.sh`), but it only runs when a human runs `just substrate-status`. Same for port squatters, frozen compiles, and a stale receipt index — all mechanically detectable, none continuously watched. **The move:** 3 lightweight watch pollers launched at wave start, emitting machine-greppable alerts to `/tmp/wave-status/<name>.log` + stderr. Human-coordinator-usable is the point: catch in minutes, not 27.

## Witnessed problem

| Class | Witnessed | Detection today | After |
|---|---|---|---|
| Leaked substrate lock | 27 min, 4 independent lane reports (dod-01, ws-09, ts-storage-blob, enclave-testbed) | on-demand `just substrate-status` | ≤15 s after condition appears |
| Orphaned beams holding ports | beams held 9443/9444/5672/5673 after parent exit | on-demand lsof | ≤15 s |
| Frozen compile / over-budget suite | concurrent lane compiles/tests, court x2 starved by a stuck compile | none | ≤30 s after threshold |
| Stale receipt index | `fin-15` regenerated `RECEIPTS.md` 5×; races noticed only on stale reads | manual regen on suspicion | ≤20 s after 5-min staleness |
| Suspect receipts | receipts lacking standing token + evidence line | caught late in review | ≤20 s |

## Design

### Common shape

- **Entry point:** `scripts/superfans.sh {up|down|status}` — same `{up|down|status}` shape as `scripts/substrate.sh`. `up` idempotently spawns the 3 poller loops (pid files in `/tmp/wave-status/*.pid`, no duplicates on re-run); `down` kills by pid file and verifies zero remain; `status` prints poller liveness + alert-log tails.
- **Implementation:** bash + python, **no new deps**, no root. Shared `scripts/superfan_lib.sh` (alert emit, dedup, ps/lsof helpers). Pollers are **report-only** — never kill, unlock, or regenerate; remediation stays with existing recipes (`just substrate-down`, `just receipt-index`).
- **Alert format** (all pollers, identical grammar): `<ISO8601Z> <ALERT-CLASS> key=value ...` — e.g. `2026-10-15T09:14:02Z ORPHAN-LOCK pid=4211 lock=/tmp/smalt-substrate.lock tree_listening=no`.
- **Output:** each alert appended to `/tmp/wave-status/<name>.log` **and** mirrored to stderr (`tail -f` in a coordinator pane or grep over the dir both work). Logs live outside the repo — zero repo churn.
- **Dedup:** alerts keyed on (class, pid-or-file); one firing per condition, re-arms on condition clear. No re-fire every poll for a persistent condition.
- **Recipes** (`justfile.d/17-superfans.just`, imported in `Justfile` after `16-*.just`):

```just
# Launch the 3 wave watch pollers (substrate/court/receipts). Report-only;
# alerts → /tmp/wave-status/<name>.log + stderr. Exit 0 spawned / 1 already running.
superfans:
    @bash scripts/superfans.sh up

# Stop all superfans and verify no poller pids remain. Exit 0 stopped / 1 still running.
superfans-down:
    @bash scripts/superfans.sh down

# Poller liveness + tail of each alert log. Exit 0 always (report-only).
superfans-status:
    @bash scripts/superfans.sh status
```

### Poller 1 — substrate-superfan (15 s interval)

Reuses the proven detectors from `scripts/substrate.sh` — `lock_holders`, `tree_listening` (flock → mix → beam, 2 levels), `orphan_holders` — extracted/sourced, not duplicated.

- **`ORPHAN-LOCK`** — flock holder of `/tmp/smalt-substrate.lock` whose whole tree has **no** LISTEN socket. Alert carries pid, lock path, cmdline. Hint text `run 'just substrate-down'`; the poller does not run it.
- **`PORT-SQUAT`** — listener on 9443/9444/5672/5673 whose pid ≠ `/tmp/smalalt-substrate-state/substrate.pid` and not a registered lane port (39050–39055, per `scripts/bench/lib.sh` `bench_boot` registrations). Alert carries pid, port, cmdline.

This converts the 27-min/4-report incident into a ≤15 s named-pid alert.

### Poller 2 — court-superfan (30 s interval)

Tails running test/compile processes (`mix compile`, `mix test`, `tsc`, `npm`, court scripts) via `pgrep` + per-pid start times from `ps -o lstart=`.

- **`COMPILE-FROZEN`** — compile/test proc alive > 10 min (`SMALT_FROZEN_SECS`, default 600). Alert carries pid, elapsed, cmdline, and **names the owner**: `git status --porcelain` dirty-file → lane attribution plus repo/worktree mtime heuristics. "Something compiling 12 min" becomes "lane ws-09's worktree compile stuck at 12 min."
- **`SUITE-WALLCLOCK`** — test-offline (or court) run over budget (`SMALT_SUITE_BUDGET_SECS`, default 900, overridable; may be seeded from latest fin-* wall-clock receipt). One fire per (suite, pid).

### Poller 3 — receipts-superfan (20 s interval)

Watches `docs/jira/<wave>/receipts/*.md`, `sdk-results/*.md`, and `RECEIPTS.md` (wave dir resolved by convention, override `SMALT_WAVE_DIR`).

- **`INDEX-STALE`** — a receipt whose mtime is >5 min newer than `RECEIPTS.md`'s (`SMALT_STALE_SECS`, default 300) and whose filename is absent from the index (filename check, not full parse). Alert carries filename, both mtimes, hint `run 'just receipt-index'` — the poller never regenerates.
- **`SUSPECT`** — receipt in `receipts/` or `sdk-results/` lacking both a standing token and a real-output evidence line. Implemented in `scripts/superfan_receipts.py`, **importing** `STANDING_TOKENS` / `EVIDENCE_PATTERNS` from `scripts/reception_index.py` — reuse, not re-implementation.

## Falsifier

Each case seeds the condition with compressed thresholds (`SMALT_FROZEN_SECS` / `SMALT_SUITE_BUDGET_SECS` / `SMALT_STALE_SECS`) and expects the first alert line (log + stderr) within 60 s of seeding.

1. **ORPHAN-LOCK:** superfans up; `flock /tmp/smalt-substrate.lock -c 'sleep 120'` in background → alert ≤ one 15 s poll after lock acquisition. Controls: superfans-down → never fires; healthy substrate → no alert in 5 min.
2. **PORT-SQUAT:** substrate down; `python3 -m http.server 9443` → alert <60 s with squatter pid + cmdline. Control: healthy substrate with matching pid-file pid → no alert.
3. **COMPILE-FROZEN:** `bash -c 'exec -a "mix compile" sleep 90'` with `SMALT_FROZEN_SECS=10` → alert <60 s, single fire, names owner. Control: proc alive under threshold → no alert.
4. **SUITE-WALLCLOCK:** same seed with `SMALT_SUITE_BUDGET_SECS=10` and proc named like a test-offline run → alert <60 s, single fire per (suite, pid). Control: run under budget → no alert.
5. **INDEX-STALE:** `touch docs/jira/v26.10.15/receipts/fake-lane.md`, don't regen index, `SMALT_STALE_SECS=10` → alert <60 s. Control: regen index after touch → no alert.
6. **SUSPECT:** drop a receipt file with neither standing token nor evidence line → alert <60 s. Control: file with `ALIVE` + `exit code 0` → no alert.
7. **Lifecycle:** `just superfans` while running → no duplicate pollers; `just superfans-down` → `pgrep -f superfan_` empty.

## Acceptance

1. `just superfans` launches exactly 3 pollers; `/tmp/wave-status/` holds 3 `.log` + 3 `.pid` files; re-run is idempotent.
2. All six seed-and-detect cases (§Falsifier 1–6) pass with alerts on **both** log and stderr within 60 s.
3. Every alert line matches `^<ISO8601Z> (ORPHAN-LOCK|PORT-SQUAT|COMPILE-FROZEN|SUITE-WALLCLOCK|INDEX-STALE|SUSPECT) ` with pid-or-file key=value context.
4. Report-only verified: after each seeded alert, the seeded condition is **still present** (lock still held, squatter still listening, receipt still unindexed).
5. `just superfans-down` leaves `pgrep -f superfan_` empty; no pollers outlive the wave.
6. Wave-level acceptance: a coordinator reading only `/tmp/wave-status/*.log` can name the lock holder / port squatter / stuck-compile owner / stale index in **minutes (one poll interval), not 27 via 4 lane reports. End-of-wave receipt `docs/jira/v26.10.15/receipts/superfans-receipt.md` records per-class alert counts and the ORPHAN-LOCK detection latency witnessed.

## Files owned

| Path | Purpose |
|---|---|
| `scripts/superfans.sh` | entrypoint `{up\|down\|status}`, idempotent spawn/teardown, pid files |
| `scripts/superfan_lib.sh` | shared: alert emit (log+stderr), dedup, ps/lsof helpers |
| `scripts/superfan_substrate.sh` | poller 1 — sources `substrate.sh` detectors |
| `scripts/superfan_court.sh` | poller 2 — proc tailing, frozen/over-budget |
| `scripts/superfan_receipts.py` | poller 3 — imports `STANDING_TOKENS`/`EVIDENCE_PATTERNS` from `receipt_index.py` |
| `justfile.d/17-superfans.just` | `superfans` / `superfans-down` / `superfans-status` recipes |
| `Justfile` | add `import 'justfile.d/17-superfans.just'` (after line 221) |
| `docs/jira/v26.10.15/receipts/superfans-receipt.md` | end-of-wave receipt (alert counts + latencies) |

### Critical Files for Implementation
- /Users/sac/smalt/scripts/substrate.sh
- /Users/sac/smalt/scripts/receipt_index.py
- /Users/sac/smalt/justfile.d/01-substrate-lock.just
- /Users/sac/smalt/justfile.d/13-receipt-index.just
- /Users/sac/smalt/Justfile