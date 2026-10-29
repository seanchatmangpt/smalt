# BK-MON3 — monitor face final standing after both fix lanes (read-only reconcile-verify)

**Standing:** PARTIAL_ALIVE — the metrics 500 is gone and the CLI face is repaired and honest end to end (BK-MON-1/-3/-4 all repaired at HEAD), but the accumulator fallback's join predicate is dead code, so the "serve live telemetry-accumulator numbers for store-miss resources" half of the fallback contract is NOT alive (BK-MON3-F1, HIGH, owner EXPL12-B/BK-MON2 lineage).

Context: solo

Lane: BK-MON3 (read-only reconcile-verify; only this receipt written). Subject: `lib/smalt/arm_gateway/router.ex` `handle_metrics/6` + fallback (~lines 1559-1617), `smalt-cli/smalt_cli/commands/monitor.py`, against a dedicated lane substrate (ports 39870-39879, auth `:enforce`, build root `_build-bkmon3`, log `tmp/bkmon3/substrate.log`).

## 1. Reconciliation of the two fixes

- HEAD carries a SINGLE convergent fix shape in `handle_metrics/6`'s fallback (router.ex:1592-1605): enumerate `Smalt.Monitor.Metrics.raw_rows/0` as a MAP — `{{r, m, b}, {c, s, mx}}` 2-tuples — instead of the pre-fix flat `{r, m, _b}` 3-tuple clause that never matched (`FunctionClauseError` → 500 on any store-miss GET with a non-empty accumulator, BK-MON-2). The clause carries the attribution comment "EXPL12-B monitor witness, 2026-10-22".
- No double-fix, no contradicting shapes, no dropped half. BK-MON2's receipt (`bkmon2-metrics-repair.md`) has NOT landed; its edits reached HEAD via tick checkpoints (534a2985/881252ea snapshot "BK-MON2 monitor.py"; 0c0729c5 EXPL12-D api-version snapshot): the api-version param (BK-MON-1), the ocel unprefixed-key fix (BK-MON-3), and the repo-root sink anchor (BK-MON-4) are all in `monitor.py` at HEAD. BK-MON2 owns `smalt-cli/` files, not `lib/smalt/monitor/metrics.ex` (unchanged since v26.10.21). Working tree: no in-flight edit to router.ex or monitor.py.
- Typed note: the fix halves are complementary, not redundant — EXPL12-B fixed the substrate route shape, the checkpoint-landed BK-MON2/EXPL12-D edits fixed the three CLI defects BK-MON registered.

## 2. Metrics GET witness (real numbers, not 500)

Dedicated lane substrate, `:enforce`, real STS token (HS256 Bearer, 1305 chars):

```
PUT  rg-bkmon3 → 201 ; PUT storageAccounts/bkmon3acct → 202 (LRO)
POST .../providers/microsoft.insights/metrics {metric:Transactions,value:42} → EMIT 200 {"value":["Transactions"]}
GET  .../storageAccounts/bkmon3acct/.../metrics?metricnames=Transactions → 200
  buckets: 1441  nonzero: [{'average': 42.0, 'count': 1, 'timeStamp': '2026-10-22T14:10:00Z', 'total': 42.0}]  unit: Count
CLI: smalt-cli monitor metrics rg-bkmon3 Microsoft.Storage storageAccounts bkmon3acct -s sub-bkmon3 --metric Transactions -o json
  exit 0; buckets: 1441  nonzero: [{'average': 42.0, 'count': 1, 'timeStamp': '2026-10-22T14:10-seal-…Z', 'total': 42.0}]
substrate log FunctionClauseError / "crash 500" matches: 0
```

Zero 500s across the whole witness session (the original BK-MON-2 state crashed on any store-miss GET once the accumulator held rows; the same state now answers 200).

## 3. BK-MON original truth probes, fresh (all hold)

- **Profile round-trip ALIVE**: isolated profile `/tmp/bkmon3-profile.json`, `login` → `verified: true`, `token_type: Bearer`, `expires_in: 3600`, profile mode 600 (`stat -f %Lp` → 600), `account show` re-read (client_secret masked `***`, tenant `test-tenant-bkmon3` preserved). Profile-driven ARM endpoint resolution honored.
- **`monitor endpoints` byte-equal: True.** CLI `-o json` output field-for-field equals direct authenticated `curl http://localhost:39870/metadata/endpoints` (`name: smalt-sovereign`).
- **`monitor ocel-tail -o json` byte-equal: True (5/5, all fields).** Live-sink comparison initially False — concurrency skew from other lanes writing between reads (different event ids/timestamps), typed NOT-A-DEFECT; frozen-snapshot comparison (`SMALT_OCEL_FILE` → `tail -40` snapshot, CLI `tail -5` vs flattened `ocel:events` of the same snapshot) is exactly equal. The CLI correctly flattens the sink's current shape (full `{"ocel:eventTypes", "ocel:events"}` documents per line), which is no longer one-event-per-line.
- **CLI metrics end-to-end** (BK-MON-1 fix path, formerly 100%-failing with HTTP 400): exit 0 with real numbers (42.0) via the api-version param at HEAD (monitor.py:53).

## 4. ty suites (fresh, this session, .venv-cli)

```
tests/test_ty_monitor.py tests/test_ty_login.py: 11 passed in 25.59s
```

## 5. Findings (typed, with owner)

### BK-MON3-F1 (HIGH, substrate, PRE-EXISTING — predicate from c72e47c3, carried through the fix) — accumulator fallback join is dead code

`router.ex:1604`: `String.starts_with?(r, String.downcase(res_id) <> "|") and m == metric` over `raw_rows/0` keys. But `Smalt.Monitor.Metrics.record/4` (metrics.ex:207-209) keys rows `{String.downcase(resource), metric, bucket}` — `r` IS the resource id, with nothing after it, so `starts_with?(r, res_id <> "|")` requires a `|` continuation that never exists. The `|` idiom belongs to `Smalt.Metrics`'s STRING-keyed table (`metrics.ex:84/97`, keys `resource|metric|bucket`), not to the monitor accumulator's tuple-keyed `:smalt_monitor_metrics`. Result: `acc_rows` is 0 for every possible res_id — the series branch is unreachable, and every store-miss metrics GET returns the real-Azure empty envelope even when the accumulator holds rows for that exact resource. Witnessed live: store-miss GET for `.../storageAccounts/noacct` (rows recorded under that path by the bandit handler via `resource_from_path/1` → 5-segment regex) returned `{"value":[]}` 200 with zero errors — under the fixed clause no crash (fix half works), but the "serve accumulator numbers" half is dead. The platform pseudo-resource is additionally unreachable as a ROUTE (its key `.../providers/Smalt.Monitor/platform` has an odd post-ns segment count the metrics route cannot form), a sub-case of F1's dead join.
- Falsifier: fix the predicate to exact/downcase-prefix matching and the same GET returns the accumulator's RequestDuration/Requests series instead of the empty envelope.
- Close condition: a live GET on a store-miss resource with accumulator rows returns the real series (200, nonzero totals), plus a route that can address the platform pseudo-resource.
- Owner: EXPL12-B/BK-MON2 lineage (router fallback + monitor accumulator owner).
- KD row candidate: no new KD row minted (single-lane, read-only lane discipline: the register edit belongs to the owner lane).

KD row candidate note: KD row minting belongs to the owner lane; recorded here as a typed finding with falsifier.

## 6. Honesty verdict

The monitor face does not invent values: every emitted value is byte-equal to the underlying face or a loud refusal/empty envelope; profile round-trip, endpoints, and ocel-tail all hold post-both-fixes; ty suites 11/11; zero 500s. But BK-MON3-F1 means the fallback's serve-rows half of its docstring contract is not alive, so the face is PARTIAL_ALIVE, not ALIVE.

## Probe cleanup

Deleted: `/tmp/bkmon3-*` (isolated profile, endpoints/ocel/metrics json, frozen ocel snapshot). Killed: lane substrate (ports 39870-39879). Left for coordinator `just lane-clean` (cleanup law): build root `_build-bkmon3` and `tmp/bkmon3/substrate.log` (replay evidence). Disclosed: `smalt-cli/.venv` created by this lane's `uv run` (gitignored; ADR-PY-002 says it should not exist — in-session removal was denied, left for the coordinator).
