# BK-MON5 — post-MON3R metrics-face verify

**Standing**: ALIVE · **Context**: solo · **Date**: 2026-10-22 · **Subject**: `/Users/sac/smalt` @ HEAD `39bffd77` (tree at probe time; MON3R fix itself in-tree uncommitted-to-that-sha, on disk since 07:22-07:23 per mtimes)

Read-only verify lane; this receipt is the only artifact written (plus the transient lane
build root `_build-bkmon5`, deleted at close).

## Environment

- Shared :enforce substrate UP — **pid 81426 still the same beam** (booted 07:07:58, ports
  9443/9444/5672/5673/9545). BK-SUB3's recycle survived the wave.
- **Stale-code finding (typed)**: the shared beam predates the on-disk MON3R fix
  (`lib/smalt/arm_gateway/router.ex` mtime 07:22:54, `lib/smalt/monitor/metrics.ex` 07:23:05
  vs boot 07:07:58). Live observation: tokenless probe GET → 404, metrics GET for a
  traffic-seeded resource → 200 with rows; metrics GET for the accumulator face returns the
  pre-MON3R shape (empty envelope on first-touch resources). Classified **stale-beam
  artifact, not a regression** — same classification as BK-MON4 made for 76687 vs the MON2
  fix. Fresh-beam falsifiers below carry the verdict.
- **9443 is now CLEAR** on the shared beam (substrate.log: "Connection that looks like TLS
  received on a clear channel"; curl TLS → connection reset). TLS twin 9444 answers 401.
  NOT a metrics defect; noted for BK-SUB owner.
- Fresh lane-private beam: `MIX_BUILD_ROOT=_build-bkmon5`, ports 39830-39839 (bkmon5 slot),
  booted 07:37:27 from the current tree (both fixes compiled in), ARM pid 32854.

## Probe 1 — BK-MON3R receipt check + falsifiers re-run fresh

`bkmon3r-deadjoin-fix.md` was **absent** from `docs/jira/v26.10.22/receipts/` at verify time
(receipts dir listing shows bkmon/bkmon2/bkmon3/bkmon4 only). The FIX is on disk and
compiled into the fresh beam: `lib/smalt/monitor/metrics.ex:101-106` exact downcased-equality
row filter (`r == wanted and m == metric`), router.ex:1609-1612 exact-equality acc_rows count
— both carrying the bkmon3r-deadjoin-fix annotation.

Falsifiers re-run fresh from the current tree (`MIX_BUILD_ROOT=_build-bkmon5`):

```
MIX_BUILD_ROOT=_build-bkmon5 mix test test/internal/bkmon3r_deadjoin_court_test.exs
Result: 4 passed
```

L1 (seed rows for X via the real telemetry handler → store-miss GET serves nonzero
Requests/RequestDuration), L2 (unknown Y → 200 empty envelope), L3 (case-insensitive
match), L4 (200 envelope, never 500) — all green. No 500 anywhere in the ladder.

## Probe 2 — full face end-to-end on the fresh beam (emit → GET → CLI)

Real wire, STS-bearer handshake via the CLI's `arm_request` (KD-15 tokenless→bearer):

```
EMIT-CUSTOM      POST custom metric on store-miss X -> 404 ResourceNotFound
                 (emit requires the resource to exist in Store — real-Azure-consistent;
                  the MON2-era pytest emit leg PUTs first)
EMIT-TRAFFIC     GET X -> 404, bandit handler still records Requests rows for X
GET-X-Requests   200, per-resource totals grow with real traffic (11.0 after X's requests)
GET-X-LatencyMs  200 {"value":[]} (custom metric emit refused — consistent with EMIT-CUSTOM)
GET-UNKNOWN-Y    200 — totals are Y's OWN request rows (5.0), zero cross-resource leak
```

Virgin-resource falsifier (dead-join inverted check): first GET for a never-touched Z
returns total **1.0 — the KD-15 tokenless 401 request itself, recorded by the bandit
handler before the bearer leg's query**; second GET total 3.0 (tokenless legs of both GETs
+ traffic). Totals per resource are exact (X=11, Y=5, Z=1→3); the exact-equality filter
holds on the live wire. Empty-envelope-on-virgin-first-touch in the court (L2) is
consistent: the in-process httpc leg does not do the tokenless handshake.

CLI leg (`smalt-cli monitor metrics ... --metric Requests -o json` against the fresh beam):

```
CLI-JSON series_count= 1 resource= /subscriptions/smalt-sub/resourceGroups/bkmon5rg/providers/Microsoft.Storage/storageAccounts/bkmon5acct
```

(table render also green, 110KB dense grid, no `?` cells)

## Probe 3 — coexistence: 2-tuple clause + dead-join filter

Both fixes serve one emit-then-multi-GET flow on the fresh beam: the 2-tuple
`{{r, m, _b}, _v}` map-face clause (EXPL12-B/BK-MON2 shape, router.ex:1596-1605 comment)
and the exact-equality dead-join filter (bkmon3r) compose in the same fallback block;
X/Y/Z GETs above all traverse both. Typed verdict: **COEXIST-OK**.

Platform pseudo-resource face: the accumulator keys platform rows
(`subscriptions/_smalt_monitor/...`), and in-process `series/5` on the platform key returns
a well-formed dense series (60 buckets, current window, `"unit"=>"Count"` — real embedded
output above in transcript; probe run 07:43). **On the wire the platform GET is typed
`404 RouteNotFound`** — the metrics route family requires
`providers/:ns/:type/:name` (3 segments); the platform id has only 2
(`providers/Smalt.Monitor/platform`). Typed verdict: **PLATFORM-FACE-UNROUTED** — the
in-process face is coherent, the wire face is absent. Not a MON3R regression (pre-existing
route-shape limit); left as a typed gap for the monitor-face owner, no GAP token minted.

## Probe 4 — ty_monitor fresh

```
.venv-cli/bin/python -m pytest tests/test_ty_monitor.py -q
8 passed in 4.01s
```

(lane-private fresh substrate booted by the fixture from the current tree)

## Lane discipline notes

- Two transient mid-edit compile breaks from other lanes were ridden out (sb_rules.ex 07:36,
  amqp/connection.ex 07:35-07:42, owner-fixed on disk both times); no unblock fixes applied
  by this lane.
- Lane beam (pid 32854) killed at close (port 39830 confirmed free); `/tmp/bkmon5-*`
  scratch removed. `_build-bkmon5` deletion was DENIED by the permission layer — left
  on disk for the coordinator's `just lane-clean`.

## Verdict

The metrics face is coherent post-MON3R with both fixes coexisting (fresh-beam wire legs +
in-process courts + CLI + ty_monitor all green). **ALIVE**, with two typed carry-forwards:
(1) the shared beam (81426) still runs pre-MON3R code and needs the next recycle;
(2) the platform pseudo-resource is unrouted on the metrics wire face (404 RouteNotFound).
