# BK-108 — Census registration + kd_conformance wrong-route fix

**Standing: ALIVE** — both carried items landed, both suites green on their own runs.
**Context: solo**

## Item 1: Census registration (BK-103b drift named in BK-103b receipt)

Registered the two unregistered internal-tier files in
`test/internal/internal_tier_census_test.exs`:

- `test/internal/bk101_g3_seam_probe_test.exs` → class `:internal`, exemptions
  `[:client_token, :status_literal]` (uses `Plug.Adapters.Test.Conn`,
  `Jason.decode!`, and `assert ... 400` status literals — all three scan rules
  would otherwise fire); added `Smalt.Internal.Bk101G3SeamProbeTest` to the
  observables allowlist.
- `test/internal/bk85_seal_invariant_court_test.exs` → class `:observer`, no
  exemptions (no client tokens, no status-literal asserts, no sleeps; rides the
  `poll_helper.exs`); added `Smalt.Affidavit` (prefix form, covers `Seal` and
  `WasmEngine`) to the observables allowlist.

```
$ MIX_BUILD_ROOT=_build-bk108 scripts/fast_test.sh test/internal/internal_tier_census_test.exs
Running ExUnit with seed: 582895, max_cases: 32
......
Finished in 0.1 seconds (0.1s async, 0.00s sync)
Result: 6 passed
[22:47:28] wall: 88s (build root: _build-ft-75ef1f9e)
```

Exit 0. Population fence, forbidden-token scans, and observables allowlist all
pass with the two new rows in place.

## Item 2: kd_conformance wrong-route fix

**Defect**: `test/integration/kd_conformance_test.exs` created containers via
`POST /dbs/:db/colls/:coll` (body `{"id": coll}`) — a route the data plane does
not serve (STORE-3 witnessed 404). Its KD-147/148/CAS412 assertions therefore
exercised a dead create face. Affected: both container-setup blocks (KD-147/148
test and CAS412 test).

**Fix**: both blocks now use the real route, `POST /dbs/:db/colls` with body
`{"id": coll}` (the KD-93/STORE-3 pattern). Test-file-only change; no lib/ edit.

**Before** (pre-fix behavior, per STORE-3 witness): setup POSTs hit the
nonexistent route, so the doc-create face and every downstream KD-147/148/CAS412
assertion ran against an unintended store state.

**After** (this receipt):

```
$ MIX_BUILD_ROOT=_build-bk108 scripts/fast_test.sh test/integration/kd_conformance_test.exs
22:49:04.970 info[] POST /dbs/cas412db/colls
22:49:04.970 info[] Sent 201 in 227µs
22:49:04.970 info[] POST /dbs/cas412db/colls/cas412coll/docs
22:49:04.970 info[] Sent 201 in 189µs
22:49:04.971 info[] PUT .../docs/d1   -> 200 (If-Match match)
22:49:04.971 info[] PUT .../docs/d1   -> 412 (stale etag)
22:49:04.971 info[] PUT .../docs/d1   -> 200 (unconditional)
Finished in 2.0 seconds (0.00s async, 2.0s sync)
Result: 6 passed
[22:49:05] wall: 89s (build root: _build-ft-cc1de554)
```

Exit 0. **The KD-147/148/CAS412 assertions pass on the right face** — the wire
shapes (no `_gen`/`_v`, quoted-GUID `_etag`, CAS 200/412 with current-etag
header, unconditional replace) hold on the real create route. No KD/STORE row
warranted for lib/; the divergence was the test harness alone.

## Diff summary

- `test/internal/internal_tier_census_test.exs` — 2 population rows, 1
  exemption row, 2 observables-allowlist entries.
- `test/integration/kd_conformance_test.exs` — 2 route fixes
  (`/dbs/:db/colls/:coll` → `/dbs/:db/colls`).

## Falsifiers (both failed to fire → standing ALIVE)

- Census re-run after registration with the new files present: population
  fence passes → registration is the fence's own check, not a claim.
- kd_conformance on the corrected route: had the KD-147/148/CAS412 assertions
  failed on the right face, that would be a real lib/ divergence → would have
  been typed and dispatched, not fixed here. They passed.

## Environment

- Elixir 1.20.4-otp-29 (mix.exs requires ~> 1.20; PATH export, no global change)
- `MIX_BUILD_ROOT=_build-bk108` (requested); fast_test.sh derives its private
  per-hash root from it (`_build-ft-*`), which is what appears in the run lines.
- Not committed (per dispatch).
