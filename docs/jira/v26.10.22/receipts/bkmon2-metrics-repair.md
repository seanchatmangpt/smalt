# BK-MON2 — monitor metrics + ocel-tail repair (BK-MON findings closed)

**Standing:** ALIVE — BK-MON-2 (substrate 500) and BK-MON-3/4 (CLI ocel-tail
faces) repaired and witnessed against real collaborators; BK-MON-1 api-version
fix landed by its owner; CLI monitor suite 8/8 green against a real
anonymous-mode substrate booted from the current tree.

Context: solo

Lane: BK-MON2 (v26.10.22). Scope: `lib/smalt/arm_gateway/router.ex` metrics
fallback, `lib/smalt/monitor/metrics.ex` (read; no edit needed — its
`raw_rows/0` map shape is the honest accumulator face; the handler was the
wrong side), `smalt-cli/smalt_cli/commands/monitor.py`, CLI court
`smalt-cli/tests/test_ty_monitor.py`.

## BK-MON-2 (HIGH, substrate) — CLOSED

Root cause confirmed by read of both sides:
`Smalt.Monitor.Metrics.raw_rows/0` returns a MAP
`%{{r, m, b} => {c, s, mx}}`; `Enum` over a map yields `{{r,m,b}, {c,s,mx}}`
2-tuples, but `handle_metrics`' accumulator fallback (`lib/smalt/arm_gateway/
router.ex` ~1596) pattern-matched a flat `{r, m, _b}` 3-tuple — clause never
matched → FunctionClauseError → 500 on ANY metrics GET once platform rows
exist. `lib/smalt/monitor/metrics.ex` needs no change (the map face is the
documented observation hook; `series/5` already aggregates correctly); the
handler was the wrong side. Fix: handler now matches the real 2-tuple shape
(`fn {{r, m, _b}, _v} ->`), with a shape comment citing the witness.

Falsifier: seed the accumulator with REAL traffic (the CLI court's
`_hit_resource_arm_path` fires a real HTTP request; the bandit `:telemetry`
stop event records `Requests`/`RequestDuration` rows), then
`GET .../providers/microsoft.insights/metrics?api-version=2024-02-01` →
200 with a real timeseries, never 500. Witnessed by
`test_metrics_live_accumulator_series` against a real anonymous-mode
substrate booted from the current tree by the conftest fixture
(reuse-else-boot under the lane lock, identity marker verified):

```
$ cd /Users/sac/smalt/smalt-cli && export PATH="$HOME/.asdf/shims:$PATH" && \
  MIX_BUILD_ROOT=_build-bkmon2 .venv-cli/bin/python -m pytest tests/test_ty_monitor.py -q -p no:cacheprovider
........                                                         [100%]
8 passed in 13.53s
```

The 8 legs: metrics 200-with-rows (live accumulator), metrics
unknown-resource empty envelope, ocel-tail json face, ocel-tail TABLE face
real values (no `?`), wrapped-document tolerance leg, default-sink
repo-anchoring leg, missing-sink ANDON, endpoints face.

## BK-MON-3 (MEDIUM, CLI) — CLOSED

Table face now reads the real per-event shape (unprefixed `id`/`type`/`time`;
bare per-event NDJSON lines AND wrapped `{"ocel:events": [...]}` documents
both flattened, `-n` counts EVENTS not physical lines). Court legs updated to
the real sink shape — the old test itself wrote the WRONG premise (wrapped
`ocel:`-prefixed document lines), the premise-rot class; corrected to per-event
unprefixed lines.

Witness (real sink, 614,756-line `tmp/ocel/events.ndjson`, run from
`smalt-cli/` cwd — also witnessing BK-MON-4):

```
$ cd smalt-cli && .venv-cli/bin/python -m smalt_cli.cli monitor ocel-tail -n 4
# ocel tail: /Users/sac/smalt/tmp/ocel/events.ndjson (last 4 events)
ev-affidavit-seal-578	affidavit.seal	2026-10-22T13:38:36.584761Z
ev-affidavit-seal-642	affidavit.seal	2026-10-22T13:38:37.770689Z
ev-affidavit-seal-71	affidavit.seal	2026-10-22T13:38:37.851543Z
ev-affidavit-seal-7	affidavit.seal	2026-10-22T13:41:28.489415Z
```

(The table renders REAL substrate event ids/types/times — every field was
`?` before the repair.)

## BK-MON-4 (LOW, CLI) — CLOSED

Default sink path is repo-root-anchored
(`Path(__file__).resolve().parents[3] / "tmp/ocel/events.ndjson"`), not
cwd-relative; `SMALT_OCEL_FILE` and `--file` still win. Witnessed: run from
`smalt-cli/` cwd with no `--file`/env, the CLI found the real repo-root sink
and rendered real events (see output above — path shows
`/Users/sac/smalt/tmp/ocel/events.ndjson` while cwd was `smalt-cli/`).
Missing sink remains a loud ANDON exit 1 (court leg `test_ocel_tail_missing_sink_andon`).

## BK-MON-1 (HIGH, CLI) — CLOSED BY OWNER

The `api-version=2024-02-01` param fix landed (EXPL12-D owner); the metrics
court legs exercise it end to end (400 → 200 flip witnessed via the green
suite).

## Substrate suites

Relevant substrate suites green on `MIX_BUILD_ROOT=_build-bkmon2`:
`mix test test/internal/plane_blast_radius_test.exs test/integration/ja10_transparency_court.exs test/internal/internal_tier_census_test.exs`
→ **15/17 passed**; the 2 failures are NOT this lane's and are disclosed for
their owners:

1. `InternalTier.CensusTest` population fence — another lane's unregistered
   on-disk file `store4_no_boot_test.exs` (in-flight census registration is
   the owner's next commit; drift is the tree, not this lane).
2. `Ja10 leg 2` transparency allowlist dead-law entry (`Smalt.Store` has no
   observed unlabeled referent) — process-allowlist drift from the concurrent
   wave, untouched by BK-MON2 (no process/label edits in this lane).

## Disclosure

- `smalt-cli/smalt_cli/commands/monitor.py` carried foreign in-flight work in
  my lane's file: the BK-MON-1 api-version fix (EXPL12-D owner) and a
  BK-MON-3 rewrite (event-count `-n` semantics, both-faces flattening) that
  superseded this lane's initial key-mapping edit mid-flight; both are
  committed together with this disclosure — the court legs cover both.
- Coordinator tick checkpoint b17a90a3 snapshotted the lane's router.ex,
  monitor.py, and test_ty_monitor.py edits to HEAD mid-session; this receipt
  is committed alone afterward.
- Lane build root `_build-bkmon2` (714M) is a lease; deletion was attempted
  at integration but refused by the session's permission boundary — left on
  disk for the coordinator's `just lane-clean` (not silently dropped).

## Receipt

- Subject: BK-MON2, repo /Users/sac/smalt @ b17a90a3 (fixes landed via
  coordinator checkpoint; receipt committed alone)
- Falsifiers run: metrics 200-with-rows (real accumulator via real traffic),
  ocel-tail table render with real values, default-sink repo anchoring,
  missing-sink ANDON — all green on the current tree
- Verification ladder: CLI court (8/8, real substrate) → substrate suites
  (15/17, 2 foreign failures disclosed) → `mix compile` clean (warnings only)
- Falsifier NOT witnessed live: the pre-fix 500 itself (the pre-existing
  failure was witnessed in BK-MON's receipt; this lane witnesses the fixed
  behavior)
