# Receipt — B-10: Soak + spike re-run (v26.10.14)

- **Date**: 2026-10-15
- **Repo**: /Users/sac/smalt @ main (518b31a, working tree)
- **Lane**: B-10 — owns `docs/jira/v26.10.14/bench/b10-soak-spike.jsonl`, this receipt, dated re-run verdict lines in `docs/STRESS/SOAK.md` / `SPIKE.md`
- **Subject**: `scripts/stress/soak.py` + `scripts/stress/spike.py` re-run on the current tree
- **Artifacts**:
  - `docs/jira/v26.10.14/bench/b10-soak-spike.jsonl` (3 records: soak run 4, soak run 5, spike)
  - raw: `/tmp/soak-results.json` (last-run overwrite; run-5 final state), `/tmp/spike-receipt.json` (schema smalt-spike/v1), logs `/tmp/b10-soak.log` (run 4), `/tmp/b10-soak2.log` (run 5), `/tmp/b10-spike.log`
- **Machine**: Apple M3 Max, 16 cores, 48 GB, Elixir 1.19.5 / OTP 28, macOS (darwin 25.2.0)

## What ran

- Soak ×2 (run 4 + confirmation run 5), 900 s at 50 rps (reduced from the
  1500 s default per lane cap), fresh substrate per run on ports
  39430-39435, anonymous auth, deferred sweeper — the script's own boot
  pattern (`scripts/bench/lib.sh` never appeared; `scripts/bench/` was empty
  at dispatch and stayed empty).
- Spike ×1, 10 cycles x 500 clients x 5 reqs + 100-handshake TLS herd, own
  substrate on ports 39510-39515.

## Script fixes required to run on the current tree (findings, not lib edits)

1. **ARM api-version now mandatory.** `GET/PUT /subscriptions...` without
   `?api-version=` returns **400** on the current tree; the 2026-10-14
   baseline ran it bare. soak.py's setup + arm ops were carrying no
   api-version; fixed to `api-version=2021-04-01` (spike.py was already
   correct).
2. **Sentinel DCR ingest now returns 204 (was 200).** soak.py expected 200;
   the current substrate answers `204 No Content`. Fixed expectation to
   `200|204`. This alone accounted for ~150 bad/min before the fix
   (a full run under the old expectation would read ~100% bogus sentinel
   errors).

Both fixes are in soak.py (scripts, not lib). The substrate behaved
consistently with its current tests; both are contract-tightening changes
from the release landing that the stress harness hadn't caught up with.

## Soak results (both runs identical in shape)

45,000 requests each at exactly 50.00 rps. Mix held (arm 27272 / cosmos
11038 / sentinel 2266 / blob 4424 in run 4).

| run | errors | error rate | 5xx | conn errors | RSS min5 → last (KB) | growth | ETS final |
|---|---|---|---|---|---|---|---|
| 4 | 12 | 0.00027 | 0 | 0 | 229,296 → 226,736 | 0.989x | 2286 |
| 5 | 9 | 0.00020 | 0 | 0 | 229,472 → 232,016 | 1.011x | 2341 |

90,000 total requests across both runs, 0 five-xx, 0 connection errors. RSS
post-minute-5 growth 0.989x / 1.011x, non-monotonic — well inside the >20%
monotonic gate, matching the baseline's GC-sawtooth shape (no leak). ETS
final ~2.3k rows = sentinel bounded-append count, same attribution as
baseline. Substrate log: `grep -c "Sent 5"` → 0.

**Error gate (FAIL by the letter of the contract, PASS on attribution)**: the
only failures were 12 / 9 `status:cosmos` errors. A 16-thread isolation probe
against a dedicated substrate reproduced the class and identified it: two
workers drawing the same per-category seq n land on the same doc id
`soak-{(n-1)//4}`, so one worker's create hits another's live doc (409) or
its just-deleted doc (404). The statuses observed were exactly 409/404. This
is a **client-side harness race** (per-worker counters + shared id space),
not substrate misbehavior — the baseline's 0 was scheduling luck with the
same latent race. Harness fix belongs to the soak lane owner (per-worker id
namespace would remove it); not made here (no lib edits / scope).

## Spike results — PASS

| Budget | Target | Prior (2026-10-14) | This run (2026-10-15) | Verdict |
|---|---| dated-line-only re-run table merged into docs/STRESS/SPIKE.md |
| Spike p95 worst cycle | < 2000ms | 261.7ms | 235.9ms (cycle 8) | PASS (improved) |
| 5xx all cycles | 0 | 0 | 0 / 25,100 | PASS |
| Post-spike recovery | < 100ms | 0.4-0.5ms | 0.5-0.6ms | PASS |
| Queue-drop / conn-refused | 0 | 0 | 0 | PASS |
| TLS herd (100) | 0 errors | p50 57.7 / p99 63.7ms | p50 58.7 / p99 65.1ms | PASS |

## Verdicts vs 2026-10-14 baseline

- **Soak: PASS-with-attribution** — memory and 5xx behavior unchanged from
  baseline; error gate tripped at 0.02-0.03% by the harness's own cosmos
  id-collision race (409/404, client-side). Latency drift: not measurable —
  the soak script does not expose per-request latency.
- **Spike: PASS** — every budget holds, worst-cycle p95 improved
  (261.7 → 235.9 ms), recovery < 1 ms, TLS herd clean.
