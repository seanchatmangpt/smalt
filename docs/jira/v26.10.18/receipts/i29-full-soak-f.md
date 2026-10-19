# i29 leg F — full-suite pre-gate soak at HEAD

- **Date**: 2026-10-19 00:32–00:47 PDT
- **Subject**: /Users/sac/smalt @ main 2e0b9b2 (dirty tree: in-flight AZB-20-lane edits — blob_storage / egress_router / arm_gateway router / queue_storage, per `git status`)
- **Command**: `MIX_BUILD_ROOT=_build-ft-fsf mix test` (from /Users/sac/smalt)
- **Context**: solo(mix test full suite, 3 complete attempts + 1 solo reclass run; concurrent lanes editing the same tree — file mtimes moved mid-observation)

## Attempts

| # | Outcome | Notes |
|---|---------|-------|
| 1 | **COMPILE-ABORT** (0 tests executed) | `test/wire/egress_wire_test.exs:1099` — `json_put/1` undefined (`undefined function json_put/1`). Compile-abort ≠ failure count (W672 census law). Owning lane fixed the file live mid-observation (mtime 00:32, `json_put` count now 0) — compile-freeze SLA honored; no lane intervention from this leg. |
| 2 | 2755 tests, **7 failures** (99 excluded), exit 2 | Full log not retained (tail-clipped); failure names unavailable for this run. Count-only. |
| 3 | 2755 tests, **3 failures** (99 excluded), exit 2 | Full log retained: `/tmp/fsf_legF_full.log` |
| 4 | 2 tests, **0 failures** | Solo rerun of failures 1+2 from attempt 3 — both PASS. |

Run-to-run failure-count variance (7 → 3) across identical commands is itself evidence of load/flake faces, not stable regressions.

## Attempt-3 failures, classified

### 1. `SmaltTest.Azsim.TopologyTest` "ARM resource PUT emits ResourceWriteSuccess to integration plane" — test/azsim/topology_test.exs:141 (assert at :187)

```
assert body["data"]["resourceUri"] == uri
left:  "/subscriptions/sub-rot/resourceGroups/rg-rot/providers/Microsoft.KeyVault/vaults/kv-rot"
right: "/subscriptions/s/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/azb10sa12355"
```

- **Class: FLAKE (load face)** — passes solo (attempt 4: `mix test test/azsim/topology_test.exs:141 test/azsim/adversarial_joe_test.exs:121` → 2 tests, 0 failures).
- Observed value is a *different test's* ROT-fixture resourceUri leaking into the assertion — cross-test interference under full-suite async load, not a code-path break. Not in the named LOAD roster; flagged as a flake face for the owning lane (topology/ARM event emission) to confirm under `--seed` bounded reruns.
- Not attributable to the AZB-20 whitelist faces (comp whitelist / cosmos / query): the assertion surface is ARM event emission, untouched by the in-flight diff.

### 2. `Smalt.Azsim.AdversarialJoeTest` "Vector 3: Half-open TCP silent partition — abrupt silent socket closure unlinks broker resources cleanly" — test/azsim/adversarial_joe_test.exs:121/127

```
** (MatchError) no match of right hand side value: {:error, :econnrefused}
```

- **Class: LOAD roster** (explicitly on the leg-F roster) — `econnrefused` dialing a test-broker port under full-suite load; passes solo.
- DetsRecovery / DrScenarios / CrashIsolation / GracefulStop / F58–F61: **0 failures** in attempt 3 (none appear in the failure list).

LOAD roster receipt: AdversarialJoe 1 face (flake, passes solo); F58, F59, F60, F61, DetsRecovery, DrScenarios, CrashIsolation, GracefulStop all green.

### 3. `Smalt.ErrorCodesDocTest` — test/error_codes_doc_test.exs:46 — "docs/ERROR_CODES.md is the byte-identical projection of the sources"

```
docs/ERROR_CODES.md is stale relative to the sources.
--- docs/ERROR_CODES.md (on disk) / +++ regenerated   (uniform hunk over ~30 `egress` rows)
```

- **Class: AZB-20-lane in-flight** — the in-flight `lib/smalt/egress_router.ex` edits (+234 lines) moved the line numbers cited in ~30 `| egress |` rows of docs/ERROR_CODES.md. The doc gate correctly refuses the drift. Remedy belongs to the owning lane: `just gen-error-codes` after the egress_router edits settle. This is doc-projection drift, not a behavioral failure.
- Consistent with the whitelist: the diff hunk is entirely over `lib/smalt/egress_router.ex` line citations.

## Classification summary

| Class | Count | Items |
|---|---|---|
| COMPILE-ABORT (attempt 1, resolved live by owner) | 1 | egress_wire_test.exs `json_put/1` (fixed 00:32) |
| LOAD roster | 1 | AdversarialJoe Vector 3 (`econnrefused` under load; solo PASS) |
| AZB-20-lane in-flight | 1 | ErrorCodesDocTest (ERROR_CODES.md line-citation drift from egress_router.ex) |
| Flake face (non-roster) | 1 | TopologyTest ResourceWriteSuccess (leaked ROT fixture URI under load; solo PASS) |
| **NEW (zero tolerance)** | **0** | — |

## Standing

**PARTIAL_ALIVE** — suite executes end-to-end (2755 tests / 7 properties / 1 doctest, exit 2 from 3 faces, none NEW). Pre-gate blocked only on: (a) owning lane regenerating ERROR_CODES.md, (b) flake faces (TopologyTest, AdversarialJoe V3) confirmed under bounded seeded reruns by their owners. No edits, no git ops, no _build deletion performed by this leg; build root `_build-ft-fsf` left in place.

Full attempt-3 log: /tmp/fsf_legF_full.log (scratch).
