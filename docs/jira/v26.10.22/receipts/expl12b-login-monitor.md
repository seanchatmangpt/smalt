# EXPL12-B: CLI `login`/`monitor` groups (EXPL12-9 closure)

**Standing: ALIVE** · Context: solo · 2026-10-22 · Lane EXPL12-B
· Closes the EXPL12-9 typed P3 (no login/monitor command group in smalt-cli).

## What landed

### 1. `login` / `logout` / `account show` (az parity, real STS round-trip)

- `smalt-cli login [--arm --egress --amqp --client-id --client-secret --tenant]`
  performs the REAL token mint (client_credentials POST to the ARM plane
  `/oauth2/v2.0/token`) FIRST and only persists the profile on a 200 carrying
  `access_token`; any refusal is ANDON (exit 1) with NO profile written.
- Profile: `~/.smalt-cli/config.json` (overridable `SMALT_CLI_CONFIG` for
  tests), JSON, chmod 0600.
- Precedence everywhere: **env > profile > defaults**.
  `smalt_cli/config.py:Settings.from_env` falls back to profile endpoints;
  `smalt_cli/wire.py` STS legs read creds via `profile.credentials()`
  (env > profile > emulator-accepted CLI defaults). Env-only operation with
  no profile file is byte-for-byte the old behavior.
- `logout` removes the profile (ANDON when absent); `account show` renders it
  with the secret masked (`***`).

### 2. `monitor` group — only faces the substrate genuinely serves

- `monitor metrics <rg> <ns> <type> <name> [--metric --timespan --interval
  --subscription]` — GET `.../providers/microsoft.insights/metrics`
  (`api-version` pinned `2024-02-01` = `Smalt.Metrics.latest_api_version/0`),
  emitting `{resource, series_count, value}`.
- `monitor ocel-tail [-n N] [--file PATH]` — tail of the real OCEL sink
  (`tmp/ocel/events.ndjson`, default repo-root-anchored, `SMALT_OCEL_FILE`
  override). `-n` counts EVENTS not physical lines: the sink's wrapped
  `{"ocel:events": [...]}` document lines carry many events each; bare
  per-event NDJSON lines are accepted too (dual-face).
- `monitor endpoints` — GET `/metadata/endpoints` (real ARM discovery face).
- Typed honestly ABSENT: the ARM gateway serves NO activity-log and NO
  metric-alerts route (`lib/smalt/monitor/activity_log.ex` /
  `metric_alerts.ex` are library modules, never routed) — so there are no
  `activity-log`/`alerts` commands. Nothing invented.

## Substrate defect found and fixed (disclosed cross-lane file touch)

`lib/smalt/arm_gateway/router.ex` `handle_metrics/6` accumulator fallback:
`raw_rows/0` returns a MAP (`%{{r,m,b} => {c,s,mx}}`); `Enum.count(map, fn
{r, m, _b} -> ...)` feeds 2-tuples into a 3-tuple clause -> FunctionClauseError
-> **500 on EVERY microsoft.insights/metrics GET** once any platform row
exists (always, after any traffic). Witnessed BEFORE on the live substrate
(pid 76687, build 26.10.19):

```
06:23:29.151 [error] arm_gateway crash 500: ** (FunctionClauseError) no
function clause matching in anonymous fn/1 in Smalt.ArmGateway.Router.handle_metrics/6
... anonymous fn({{"subscriptions/_smalt_monitor/resourcegroups/_smalt_monitor/providers/smalt.monitor/platform", "Requests", 1792671900000}, {1, 1.0, 1.0}})
```

Fix: 2-tuple clause `fn {{r, m, _b}, _v} -> ...` (router.ex ~1580, comment
cites this receipt). AFTER: clean 200 envelope. `docs/ERROR_CODES.md`
regenerated as the rider of that line-shift (generated artifact, never
hand-edited).

## Witnesses (real substrate, real wire)

Live-substrate login (fixed lane substrate on 39611; live prod substrate
76687 bore the login witness too on 9443 — same output shape):

```
$ smalt-cli login --arm http://127.0.0.1:39611 --egress http://127.0.0.1:39612 \
    --client-id expl12b --client-secret expl12b-local -o json
{
  "verified": true,
  "profile": "/tmp/expl12b-profile2.json",
  "arm": "http://127.0.0.1:39611",
  "egress": "http://127.0.0.1:39612",
  "amqp": "127.0.0.1:5672",
  "tenant": "00000000-0000-0000-0000-000000000000",
  "token_type": "Bearer",
  "expires_in": 3600
}
$ ls -l /tmp/expl12b-profile2.json   ->  -rw------- (0600)
```

Profile-only operation with NO env endpoints (env vars explicitly unset;
`account show`, `monitor endpoints`, `monitor metrics`, `monitor ocel-tail`
all ride the profile). `monitor endpoints` head:

```
{"activeDirectoryEndpoint": "http://127.0.0.1:39611/", "authentication":
 {"audiences": ["https://management.azure.com"], "identityProvider": "AAD",
  "loginEndpoint": "http://127.0.0.1:39611/", "tenant": "common"}, ...}
```

`monitor metrics` after a REAL resource PUT (202) + REAL custom-metric emit
POST (200), queried through the CLI with profile-only config:

```
series_count= 1
points: [{'average': 7.0, 'count': 1, 'timeStamp': '2026-10-22T13:32:00Z', 'total': 7.0}]
```

`monitor ocel-tail -n 2 -o json` against the real repo sink (614,617 lines,
last line rendered):

```
[{"attributes": {"engine_hash": "sha256:2d0c38...", "subject_sha":
  "1c58e2e...", "verdict": "admitted"}, "id": "ev-affidavit-seal-259", ...}]
```

`logout` -> `logout: profile removed`.

ANDON legs: dead-port login -> exit 1 ANDON, no profile file; missing sink ->
exit 1 ANDON; unknown-resource metrics -> 200 with the real-Azure EMPTY
`value[]` envelope (not an error).

## Tests (Chicago: real wire, real sinks, no mocks)

- `tests/test_ty_login.py` (3): login verifies + persists (temp
  SMALT_CLI_CONFIG); `account show` masking; env>profile fallback proven by a
  real `monitor endpoints` wire call with NO env endpoints; logout removal +
  post-logout ANDON; dead-port STS refusal ANDON with no profile persisted.
- `tests/test_ty_monitor.py` (8): live custom-metric series (real PUT +
  real emit + CLI query, `"total": 42` datapoint surfaced); unknown-resource
  empty envelope; ocel-tail bare/wrapped dual-face; table face renders real
  id/type/time values; default sink repo-root-anchored; missing-sink ANDON;
  endpoints discovery face.

Full regression (`SMALT_CLI_LANE=expl12b MIX_BUILD_ROOT=_build-lane-expl12b
pytest tests/ -q`): **146 passed, 2 skipped** (first run 145 passed + 1
failed — my router.ex edit shifted ERROR_CODES line citations; regenerated
`docs/ERROR_CODES.md` via `just gen-error-codes` (254 rows), re-run clean).
Package lanes (`pytest smalt_cli/ -q`): **102 passed**.

## Falsifier status

- Login fabricates a profile without a real mint -> REFUTED (dead-port leg
  exits 1 with no file).
- monitor invents a face the substrate doesn't serve -> REFUTED (commands
  enumerate exactly the routed faces; activity-log/alerts absent and named).
- ocel-tail renders "?" on the real sink -> REFUTED (real 614k-line sink
  renders real ids).
- metrics face 500s on any query -> REFUTED (router fix + court leg).

## Residue (honest)

- `amqp` profile field is stored/loaded but no AMQP wire face consumes it yet
  (servicebus data plane still reads env/default) — recorded, not hidden.
- `account show` masks the secret; the profile file itself is plaintext
  0600 loopback-only (emulator-accepted dummy creds by design).
- Build root `_build-lane-expl12b` left as this lane's compile lease (warm;
  coordinator may reclaim with `just lane-clean`).
