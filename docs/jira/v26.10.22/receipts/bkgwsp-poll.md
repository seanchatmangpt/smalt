# BK-GWSP — BK-GWSSKEP liveness poll

- **Standing**: PARTIAL_ALIVE (BK-STAND6: census receipt — embedded output is complete and typed: freeze age 62 min, 0 build-root writes in 25 min, 2 orphaned `--hang` stub beams, 0 gwsskep receipts; lane verdict FROZEN is a lifecycle disposition, not a capability standing; superseded by the GWSSKEP2 relaunch)
- **Context**: solo
- **Lane**: BK-GWSP (read-only census lane)
- **Date**: 2026-10-22 07:26–07:30 PDT

## Census (embedded)

All commands run fresh 2026-10-22 ~07:26–07:29 PDT.

**Build-root last write**: newest file in `_build-bkgwsskep` is
`test/lib/smalt/.mix/.mix_test_failures`, mtime epoch `1792675472`
(≈06:24 PDT); at census time `now=1792679230` → **age 62 min**, far past the
20-min FROZEN threshold. Top of the newest-write list:

```
1792675472 _build-bkgwsskep/test/lib/smalt/.mix/.mix_test_failures
1792675467 _build-bkgwsskep/test/lib/smalt/consolidated/Elixir.Ymlr.Encoder.beam
1792675467 ... consolidated beams at 1792675467 (≈06:24:27)
```

`find _build-bkgwsskep -type f -newermt '-25 minutes'` → **zero files**.

**Processes from the build root**: `ps aux | grep bkgwsskep` → exactly two
beams, both running
`_build-bkgwsskep/test/lib/smalt/priv/wasm/stub_runner.exs --hang`:

```
PID  5450  started 06:24:30  %CPU 0.0  PPID 1 (launchd-reparented)
PID 66298  started 06:03:47  %CPU 0.0  PPID 1 (launchd-reparented)
```

Both are 0%-CPU `--hang` test stubs reparented to launchd — tree-aware
orphan stubs, not active work. **No process with
`MIX_BUILD_ROOT=_build-bkgwsskep` is running any mix test** (checked `ps eww`
on the live mix tests at 07:24–07:26: their build roots are `_build-bkgwsv`,
`_build-bkmon5`, `_build-bkwit3r-kfkskep` — other lanes).

**Owned-surface mtimes**: `test/internal/gld6_sql_row_gate_court.exs`
mtime 2026-10-21 17:19:55 (predates the window); no `sqld2_sql_ingest_court.exs`
on disk (path does not exist — typed so the relaunch doesn't wait on it);
`bkmon3r_deadjoin_court_test.exs` mtime 07:23:39 — owned by the bkmon5 lane,
not GWSSKEP.

**Receipt on disk**: zero files matching `gwsskep` under
`docs/jira/v26.10.22/receipts/` (grep -ci → 0) and zero anywhere in
`tmp/` or `docs/jira/v26.10.22/` — not LANDED.

## Verdict

**FROZEN** — no writes in >20 min (62 min), no active work on the build root,
only two orphaned `--hang` stub beams, no receipt.

## Completed-court typing for the GWSSKEP2 relaunch

No GWSSKEP-named fragments exist (no `bkgwsskep*` file anywhere). The only
gws/sqld/gld scratch under `tmp/` predates today's window or belongs to other
lanes:

```
tmp/bench/gws8-wasm-native.jsonl     Oct 21 16:05
tmp/bench/sqld8-ingest-baseline.jsonl Oct 21 16:38
tmp/gws8  tmp/gld5  tmp/gld5fix  tmp/gld1-court-result.terms  Oct 21
tmp/sqld8  Oct 22 05:55 (pre-window, other lane)
```

**Type for relaunch: assume NO wave courts completed by GWSSKEP; GWSSKEP2
re-runs the full GWS/SQLD/GLD/BENCH wave.** Nothing is attributable; do not
skip any court. The two orphaned stub beams (PIDs 5450, 66298) are safe for
the coordinator to reap by exact PID alongside the TaskStop.

## Falsifier

A landed `bkgwsskep*` receipt or a build-root write newer than 06:24 would
invert this verdict; both checked absent at census time.
