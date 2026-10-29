# BK-MON — monitor-face honesty verification (EXPL12-B follow-up)

**Standing:** PARTIAL_ALIVE — zero fabricated values witnessed anywhere on the monitor face; profile round-trip ALIVE; but `monitor metrics` is dead-on-arrival against the live substrate (BK-MON-1 CLI defect + BK-MON-2 pre-existing substrate 500) and the ocel-tail table face is lossy (BK-MON-3).

Context: solo

Lane: BK-MON (read-only verify, v26.10.22). Subject: `smalt-cli/smalt_cli/commands/monitor.py`, `login.py`, `profile.py` (EXPL12-B face) against the live substrate (pid 76687, ports 9443/8443/9444, auth `:enforce`).

## What was verified ALIVE

- **Login profile round-trip: works end to end.** `smalt-cli login` (isolated profile `SMALT_CLI_CONFIG=/tmp/bkmon-profile-95438.json`) performed the real STS round-trip against `http://localhost:9443/.../oauth2/v2.0/token` (HTTP 200, `token_type: Bearer`, `expires_in: 3600`), persisted the profile to `$SMALT_CLI_CONFIG` with mode 600 (`stat -f "%Lp"` → `600`), and `account show` re-read it (client_secret masked `***`, tenant `test-tenant-bkmon` preserved). Endpoint fallback honored: with `SMALT_ARM`/`SMALT_EGRESS` unset, `monitor endpoints` resolved the ARM base from the profile and returned 200.
- **`monitor endpoints`: substrate-sourced, byte-equal.** CLI JSON output is field-for-field identical to a direct authenticated `curl http://localhost:9443/metadata/endpoints` in the same shell (same `name: smalt-sovereign`, same 13 dnsSuffixes, same audiences). No invention.
- **`monitor ocel-tail -o json`: substrate-sourced, byte-equal.** CLI JSON output equals `tail -5 tmp/ocel/events.ndjson` parsed per-line, exactly 5/5 events, `all(c==d)` True. The sink is real (614,648 lines, tmp/ocel/events.ndjson); the missing-file case is a loud ANDON exit 1 (`ocel sink not found`), never a fake pass.

## Findings (typed, falsifiers embedded)

### BK-MON-1 (HIGH, CLI) — `monitor metrics` omits the required `api-version` and can never succeed

`monitor.py:_metrics_url`/`metrics()` builds the URL and passes only `metricnames`/`timespan`/`interval` as params — no `api-version`. The ARM gateway requires it (`lib/smalt/arm_gateway/router.ex` `check_api_version(conn, nil)`):
```
$ smalt-cli monitor metrics rg-bkmon Microsoft.Storage storageAccounts bkmonacct -o json
ANDON monitor metrics refused (HTTP 400)   # CLI_EXIT=1
$ curl -s -H "Authorization: Bearer $TOK" "$URL"   # same URL, no api-version
{"error":{"code":"MissingApiVersionParameter","innererror":{},"message":"The api-version query parameter is required."}}
```
Same 400 for both. The command as shipped is 100% failing against the live substrate. Fix shape: append `api-version=2024-02-01` (the substrate's `@latest_api_version`, `lib/smalt/metrics.ex:24`) to the query params. DISCLOSURE (2026-10-22, post-receipt): the worktree now carries an in-flight one-line fix to `monitor.py` (`extra = {"api-version": "2024-02-01"}`) from another lane (EXPL12-D owner per checkpoint 0c0729c5) — matching this fix shape; not this lane's edit, not committed here. Note that BK-MON-2 (substrate 500) will still surface once BK-MON-1 lands: the CLI's 400 will become a surfaced-andon of the route's 500.

### BK-MON-2 (HIGH, substrate, PRE-EXISTING 26.10.19 — not session-introduced) — metrics route 500s whenever the telemetry accumulator is non-empty

Even with a valid `api-version=2024-02-01`, `GET .../providers/microsoft.insights/metrics` crashes:
```
{"error":{"code":"InternalServerError",...,"target":"...storageAccounts/bkmonacct/..."}}
```
Substrate log (`/tmp/smalt-substrate-state/substrate.log`):
```
06:20:28.721 [error] arm_gateway crash 500: ** (FunctionClauseError) no function clause
  matching in anonymous fn/1 in Smalt.ArmGateway.Router.handle_metrics/6
  (smalt 26.10.19) lib/smalt/arm_gateway/router.ex:1536: anonymous fn({{"subscriptions/_smalt_monitor/resourcegroups/_smalt_monitor/providers/smalt.monitor/platform", "Requests", 1792671900000}, {1, 1.0, 1.0}})
```
Root cause read from tree: `Smalt.Monitor.Metrics.raw_rows/0` (lib/smalt/monitor/metrics.ex:153-158) returns a MAP keyed `{r, m, b}` with value `{c, s, mx}` — iterating it yields `{{r, m, b}, {c, s, mx}}` 2-tuples. The router's accumulator fallback (`lib/smalt/arm_gateway/router.ex`, `handle_metrics`, current-tree ~line 1567) pattern-matches a flat `{r, m, _b}` 3-tuple, so the clause never matches and ANY metrics GET crashes 500 whenever the accumulator holds >=1 row globally (the platform monitor always has rows, so the route is dead in practice on a lived-in substrate; it only 200s with the empty envelope on a cold accumulator). Note: this also refutes the docstring's "unknown resource -> EMPTY envelope" premise — that holds only when the accumulator is empty.

### BK-MON-3 (MEDIUM, CLI) — ocel-tail table face is lossy (renders `?` for every field), not fabricated

Table renderer reads `ocel:id`/`ocel:type`/`ocel:time` keys; the substrate's OCEL 2.0 events use unprefixed `id`/`type`/`time` (witnessed top-level keys `ocel:eventTypes/ocel:events/ocel:objectTypes/ocel:objects` with per-event keys `attributes/id/relationships/time/type`). Every table row renders `?\t?\t?`. JSON output is faithful; the table face shows zero information while implying it tailed the file (it did — JSON mode proves it). Fix shape: read `e["id"]`, `e["type"]`, `e["time"]`.

### BK-MON-4 (LOW, CLI) — ocel-tail default sink path is cwd-relative

Default `tmp/ocel-relative` resolution means running from outside the repo root ANDONs with `ocel sink not found: tmp/ocel/events.ndjson` even though the substrate sink exists (witnessed from `smalt-cli/` cwd). Loud failure, no fabrication, but the default should anchor to the repo root or the substrate-reported sink path.

## Honesty verdict

The monitor face does NOT invent values: every value it emits is either byte-equal to the underlying face (endpoints, ocel-tail json) or a loud ANDON refusal (metrics 400, missing sink). The failures are honesty-preserving failures — but BK-MON-1 means the flagship `metrics` command has never worked against the live substrate as shipped, and BK-MON-2 means the substrate route it should hit is itself broken on any lived-in substrate. PARTIAL_ALIVE, with 2 HIGH defects registered above for repair lanes.

## Probe cleanup

Isolated profile /tmp/bkmon-profile-95438.json and scratch json under /tmp removed; in-emulator probe artifacts (rg `rg-bkmon` PUT 201, storage-account PUT 404-not-created) leave an RG record in the emulator's in-memory/DETS state only — no external system touched.
