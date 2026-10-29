# BK-MON6 — metrics-face integrity verify: cross-resource leakage under the MON3R filter

**Standing:** ALIVE — the integrity property holds: the new exact-equality filter serves each resource ONLY its own accumulator rows (zero cross-resource leakage), both fixes coexist on the current tree, no 500 anywhere.

Context: solo

Lane: BK-MON6 (read-only verify; only this receipt written). Subject: current working tree (`lib/smalt/arm_gateway/router.ex` handle_metrics fallback + `lib/smalt/monitor/metrics.ex` series/5), probed via a fresh self-booted app on lane ports 39861-39868, `MIX_ENV=test`, build root `_build-bkmon6`.

## 0. Coordination (both upstream receipts landed)

- `bkmon3r-deadjoin-fix.md` landed 07:34; `bkmon5-metrics-verify.md` landed 07:45. Both read; no duplication: BK-MON5 seeded via bandit traffic (Requests totals 11/5/1→3) and re-ran the L1-L4 courts; THIS lane seeds X and Y directly with **distinct RequestDuration values** (X=111ms, Y=222ms) so leakage is attributable per-value, not per-count — a subset BK-MON5 did not cover.
- Beam identity: shared beam **81426 is STILL the live 9443 holder at probe time (07:50) and still pre-MON3R-stale** (booted 07:07:58, fix mtimes 07:22-07:23 — BK-MON5's stale-beam finding re-confirmed, not re-verified live). My witnesses are fresh-compile beams from the current tree (`_build-bkmon6` + the fast_test per-hash root); carry-forward for BK-SUB owner: 81426 needs the next recycle.

## 1. Unique slice — X/Y integrity property (record-path seeding, real wire)

Probe: real `:telemetry.execute([:bandit, :request, :stop])` events into the real attached handler (lands in `record/4`, the accumulator's record path — record/4 itself is defp; this is the faithful public route), real HTTP/1.1 GETs over loopback against the self-booted `ArmGateway.Router`, no mocks, no sleeps. Embedded output (mix run, 07:50:26):

```
ARM router on http://127.0.0.1:39861
GET X  RequestDuration status=200 total=111.0  (expect 200, 111.0)
GET Y  RequestDuration status=200 total=222.0  (expect 200, 222.0)
GET Z(sibling) RequestDuration status=200 total=0.0  (expect 200, 0.0)
GET X Requests status=200 total=2.0  (the two X GETs themselves)
INTEGRITY-XOR-Y: PASS
```

- X's GET returns only X's 111ms rows; Y's returns only Y's 222ms rows — neither value appears in the other's envelope. The sibling Z (`xbk6acctx`, the pipe-continuation shape the dead `|` prefix WOULD have matched) gets an empty envelope: exact-equality, not prefix.
- No 500: all four GETs 200 (log shows `Sent 200 in …` x4, zero errors).

## 2. Coexistence on the current tree

```
MIX_BUILD_ROOT=$PWD/_build-bkmon6 scripts/fast_test.sh test/internal/bkmon3r_deadjoin_court_test.exs
Result: 4 passed   (wall 9s, per-hash root _build-ft-75715b96)
```

The 2-tuple `{{r,m,_b},_v}` clause, the exact-equality fallback predicate, and the series/5 row filter all serve the same flow (L1 traverses all three). Both fixes coexist; no 500.

## 3. ty_monitor fresh

```
MIX_BUILD_ROOT=/Users/sac/smalt/_build-bkmon6 .venv-cli/bin/python -m pytest tests/test_ty_monitor.py -q
8 passed in 3.42s
```

## Verdict

ALIVE. Falsifier for the standing: a wire GET on a seeded resource returning the sibling's value, or any 500 on a store-miss GET with a non-empty accumulator, inverts this receipt.

## Lane discipline

- Probe script was `/tmp/bkmon6_probe.exs` (outside the repo; deleted at close).
- Left for coordinator `just lane-clean`: `_build-bkmon6` (fast_test's `_build-ft-75715b96` is fast_test's own per-hash root management).
- No repo file edited other than this receipt.