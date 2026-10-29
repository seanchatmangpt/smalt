# BK-MON4 — final consolidated monitor-face verify

**Standing**: ALIVE · **Context**: solo · **Date**: 2026-10-22 · **Subject**: `/Users/sac/smalt` @ HEAD `daea2d87`

Read-only verify lane. No lib/, test/, or CLI code edits; this receipt is the only artifact.
`bkmon3-final-standing.md` was absent from `docs/jira/v26.10.22/receipts/` at verify time, so no
dedupe against it — **all probes below are this lane's own fresh runs**.

## Environment

- Shared :enforce substrate UP (pid 76687, booted 05:19), ports 9443/9444/5672/5673.
- Lane-private anonymous + enforce substrates (lane `bkmon4`) booted from the current tree by the
  pytest fixture.
- `.venv-cli`, asdf shims first on PATH.

## Probe 1 — BK-MON-2: metrics 200-with-rows, not 500

Fix verified on disk by Read: `lib/smalt/arm_gateway/router.ex:1596-1605`, the accumulator
fallback counts rows with the real map-face clause
`Enum.count(fn {{r, m, _b}, _v} -> ... end)` over `Smalt.Monitor.Metrics.raw_rows()`.

Shared-beam observation: the shared :enforce beam (pid 76687) serves **HTTP 500** on the metrics
face. Classified **stale-beam artifact, not a regression**: the beam booted 05:19 and the
BK-MON-2 fix landed 06:55 (commit `368c32d5`, `git log -1 --format='%h %ci' 368c32d5` →
`2026-10-22 06:55:54 -0700`), so the running beam holds pre-fix router code. The shared substrate
was not restarted (other lanes live on it).

Fresh-beam falsifier, green on a lane-private anonymous substrate booted from the current tree:

```
tests/test_ty_monitor.py::test_metrics_live_custom_metric_series PASSED
tests/test_ty_monitor.py::test_metrics_unknown_resource_empty_envelope PASSED
```

Real custom-metric POST emit → CLI `monitor metrics` **200 with `series_count` rows**; unknown
resource → real-Azure empty `value[]` envelope, 200, never an error.

## Probe 2 — BK-MON-3: ocel-tail table renders real values, zero `?`

Run A — from `smalt-cli/` cwd, `-n 5` (exit 0):

```
# ocel tail: /Users/sac/smalt/tmp/ocel/events.ndjson (last 5 events)
ev-affidavit-seal-134	affidavit.seal	2026-10-22T13:52:22.994903Z
ev-affidavit-seal-21186	affidavit.seal	2026-10-22T13:53:12.594723Z
ev-affidavit-seal-9	affidavit.seal	2026-10-22T13:56:23.283882Z
ev-affidavit-seal-7	affidavit.seal	2026-10-22T13:57:02.191761Z
ev-affidavit-seal-12226	affidavit.seal	2026-10-22T13:57:44.562099Z
```

Run B — from foreign cwd `/tmp` with `PYTHONPATH=/Users/sac/smalt/smalt-cli`, `-n 3` (exit 0):

```
# ocel tail: /Users/sac/smalt/tmp/ocel/events.ndjson (last 3 events)
ev-affidavit-seal-9	affidavit.seal	2026-10-22T13:56:23.283882Z
ev-affidavit-seal-7	affidavit.seal	2026-10-22T13:57:02.191761Z
ev-affidavit-seal-12226	affidavit.seal	2026-10-22T13:57:44.562099Z
```

All rows carry unprefixed `id<TAB>type<TAB>time`; zero `?` cells in either run.

## Probe 3 — BK-MON-4: default sink repo-root-anchored

Run B above ran from `/tmp` (no repo cwd) and still resolved the default sink to
`/Users/sac/smalt/tmp/ocel/events.ndjson` via the `parents[3]` anchor in
`smalt-cli/smalt_cli/commands/monitor.py:88-90`. Court test green:
`tests/test_ty_monitor.py::test_ocel_tail_default_sink_repo_anchored PASSED`.

## Probe 4 — BK-MON-1: api-version accepted

All metrics legs ride `api-version=2024-02-01` (`smalt-cli/smalt_cli/commands/monitor.py:52`) and
pass on the fresh beam (`test_metrics_live_custom_metric_series`,
`test_metrics_unknown_resource_empty_envelope`). Accepted.

## EXPL12-W arm_request challenge trace (live, real wire)

Against the shared :enforce substrate, `resourcegroups` face:

```
LEG1 tokenless: 401 | WWW-Authenticate: Bearer authorization="https://127.0.0.1:9443/organizations",
LEG2 arm_request: 200
```

Tokenless first touch takes the 401 + `WWW-Authenticate`; `wire.arm_request` mints the STS bearer
and retries to 200. (Note: the `metadata/endpoints` face is tokenless-allowed on this substrate —
a tokenless GET there returns 200 with no challenge — so the resourcegroups face is the honest
challenge witness.)

## Suites fresh (lane `bkmon4`)

```
anonymous: 11 passed, 3 deselected in 24.94s
enforce:    3 passed, 11 deselected in 24.60s
```

Anonymous names:

```
test_metrics_live_custom_metric_series PASSED
test_metrics_unknown_resource_empty_envelope PASSED
test_ocel_tail_reads_real_sink PASSED
test_ocel_tail_table_renders_real_values PASSED
test_ocel_tail_default_sink_repo_anchored PASSED
test_ocel_tail_wrapped_document_still_parsed PASSED
test_ocel_tail_missing_sink_andon PASSED
test_endpoints_discovery_face PASSED
test_login_verifies_and_persists PASSED
test_logout_removes_profile PASSED
test_login_sts_refusal_is_andon_no_profile PASSED
```

Enforce names:

```
test_arm_get_kd15_handshake_on_enforce PASSED
test_sts_refusal_is_typed_andon_never_silent_tokenless PASSED
test_cli_monitor_endpoints_rides_handshake_on_enforce PASSED
```

Env hazard note (lane-relevant, not a face defect): with ambient Elixir 1.19.5 first on PATH, the
fixture's substrate boot dies pre-ready — `(Mix) You're trying to run :smalt on Elixir v1.19.5
but it has declared in its mix.exs file it supports only Elixir ~> 1.20` — and every test SKIPS
loudly. `$HOME/.asdf/shims` must lead PATH for any lane running the ty suites.

## Standing

ALIVE — the monitor face holds as one coherent post-all-fixes surface on merged HEAD
`daea2d87`: metrics 200-with-rows on a fresh beam, ocel-tail real values from any cwd,
root-anchored default sink, api-version 2024-02-01 accepted, and the EXPL12-W challenge
handshake witnessed live on real wire. The only red observed (metrics 500) was on the shared
beam whose code predates the fix — an ops-staleness fact recorded here for the substrate owner,
not a face regression.
