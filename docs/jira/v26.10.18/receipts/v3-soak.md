# Receipt: v3-soak — 3x full-suite soak, failure-identity classification
Context: full (mix test, full suite x3, logs /tmp/v3-soak-run{1,2,3}.log, _build-ft-v3)

Date: 2026-10-18 (~21:15–21:55 PDT) · Tree: working tree at `git rev-parse HEAD` = `efd8e1c` (HEAD moved twice mid-session: `014bb7a` at run 1/2 → `efd8e1c` at run 3).
Lane: bench-runner soak v3 RELAUNCH (prior instance died on a 429 at run 2 of 3; runs 1–2 logs inherited verbatim).
Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}` (`just bench-machine`).
Build root: `MIX_BUILD_ROOT=_build-ft-v3`.

## Runs (MIX_BUILD_ROOT=_build-ft-v3 mix test, full suite, shared tree under concurrent lanes)

```
tail -1 /tmp/v3-soak-run1.log
1 doctest, 7 properties, 2710 tests, 32 failures (93 excluded)
tail -1 /tmp/v3-soak-run2.log
1 doctest, 7 properties, 2710 tests, 11 failures (93 excluded)
tail -1 /tmp/v3-soak-run3.log
1 doctest, 7 properties, 2710 tests, 24 failures (93 excluded)
```

Run 1: 178.7 s. Run 2: 141.2 s. Run 3: 110.4 s. All 3 runs completed on the same
2710-test suite. Run 3 was BLOCKED ~15 min by a foreign in-flight edit to
`test/azsim/azure_common_issues_test.exs` (`Code.require_file(..., "/burn-evidence")`,
target absent on this tree → compile abort). The owning lane fixed it at ~21:37
(within the compile-freeze SLA); run 3 launched on the fixed tree — no edits from
this lane.

## Failure identities (verbatim)

### Run 1 — 32 failures (/tmp/v3-soak-run1.log)

| # | Identity | Error |
|---|---|---|
| 1 | `test/azsim/azure_common_issues_test.exs` Vector 1 ETag race & atomic CAS | `Expected exactly 1 winner, got 0` |
| 2 | same file, Vector 6 malformed CloudEvent refused 400 | MatchError |
| 3 | `test/error_codes_doc_test.exs:46` ERROR_CODES.md byte-identical projection | doc stale vs sources (diff shown; `Regenerate: python3 scripts/gen_error_codes.py`) |
| 4–9 | `test/semantic_projection_test.exs` x6 (R2RML compile, domain read, cross-surface validation x4, render determinism) | MatchError / `Ash.Error.Unknown` |
| 10–31 | `test/mcp_wire_test.exs` x22 (initialize, tools/list, tools/call, blob.list, kv.get, arm.get, substrate.*, actuation refusals, lens4/5/6/8, doctor.summary, concurrency) | **ALL 22**: `(MatchError) no match of right hand side value: {:error, :econnrefused}` at `wire_rpc/3` (`test/mcp_wire_test.exs:64`) |
| 32 | `test/pplan_test.exs` lens7 half-degraded Store-down | `(EXIT from #PID<0.203382.0>) an exception was raised` (F23/i27 family) |

### Run 2 — 11 failures (/tmp/v3-soak-run2.log)

| # | Identity | Error |
|---| above | --- |
| 1–4 | `test/azsim/topology_test.exs` x4 (ResourceWriteSuccess event, foreign-issuer 401 x2, STS-over-wire) | `{:error, :econnrefused}` in `mint_over_wire` via `test/support/wire_helpers.ex:146` — identity STS not reachable under load |
| 5–6 | `test/wire/arm_wire_test.exs` x2 (Bearer GET /subscriptions, POST token) | `{:error, :econnrefused}` same helper |
| 7 | `test/error_codes_doc_test.exs:46` | doc stale (same as run 1 #3) |
| 8–9 | `test/malformed-or-incomplete` Vector 6 + Vector 1 ETag CAS | MatchError; `Expected exactly 1 winner, got 0` |
| 10–11 | `test/metadata_endpoints_test.exs` x2 (openid-configuration, POST token JWT) | advertised `token_endpoint` returned **503** under load |

### Run 3 — 24 failures (/tmp/v3-post-fix tree)

| # | Identity | Error |
|---|---|---|
| 1 | `test/azsim/topology_test.exs:141` ResourceWriteSuccess | **NEW signature**: `Assertion with == failed` — event body `resourceUri` = `/subscriptions/s/.../azb10sa16067` (corpus-seeded azb-10 store) vs expected `/subscriptions/sub-corpus/.../corpusstore` — cross-test bleed from corpus seeding, NOT econnrefused |
| 2 | `test/wire/egress_wire_test.exs:55` Cosmos create 201 | got **503** under load |
| 3–24 | `test/mcp_wire_test.exs` x22 (same cluster as run 1, near-identical membership) | **ALL 22**: `{:error, :econnrefused}` at `wire_rpc/3` |

## Classification vs FLAKE_LEDGER F18–F23 (window-2 rows)

| Ledger row | Recurrence this window | Evidence |
|---|---|---|
| F18 (`store_churn_test.exs:37`) | **0** — no `store_churn` string in any run log | grep -c = 0/0/0 |
| F19/F20 (torn DETS `not_a_dets_file`/`needs_repair`) | **0** | grep -c = 0/0/0 |
| F21 (wasm failclosed `stop_engine/0` noproc) | **0** | no noproc face |
| F22 (semantic_epoch `89.56` ratio) | **0** | no ratio face |
| F23 (C1 saturation-timeout class) | **0 C1 faces** — `grep -c TimeoutError` = 0/0/0. **BUT the conn-refusal face of the same saturation family is the dominant class this window**: 22+4+2+1 econnrefused + 2+1 503 = 32 conn-refusal/503 failures across 3 runs, all load-correlated, all solo-green per i27's ROTATING-LOAD verdicts (TopologyTest 0/2 solo) and consistent with the F23 disposition question (stress tier vs per-test budget) |

**New face worth registering**: the McpWire 22-test cluster failed as a whole-file
econnrefused block in runs 1 and 3 (44 of 67 total failures). This is not 22
independent defects — it is ONE mechanism: the MCP wire listener (bandit) did not
come up (or was torn down mid-run) under fleet load, so every `wire_rpc/3` call
got econnrefused. Recommend a single ledger row (F23-family, conn-refusal face)
for the McpWire whole-file cluster, not per-test rows.

Run 3's TopologyTest face is a different NEW signature (corpus resourceUri bleed
into the ResourceWriteSuccess event body assertion) — NEW-UNTRIAGED, needs its own
solo bisect before a row.

## Deterministic-pair status (enclave residue + doctor/mcp tree)

- `docs/jira/v26.10.18/receipts/i27-deterministic-pair.md` **does not exist** —
  the deterministic-pair receipt has not been written.
- The enclave-residue fix has **not landed**: no uncommitted or committed diff to
  `lib/smalt/enclave/lifecycle.ex` on this tree; `ORPHANED_DATA_PLANE_ROWS_DETECTED`
  gate at `lib/smalt/enclave/lifecycle.ex:164` unchanged; no `resourcewritesuccess`
  queue deletion added. i27's DETERMINISTIC enclave cluster row remains
  **diagnosed, not fixed**.
- Consistent witness: run 3's TopologyTest assertion face showed the
  `resourcewritesuccess`-queue ecosystem still mutating event bodies (azb10 store
  bleed) — same neighborhood as i27's residue row.
- doctor/mcp tree leg: `doctor.summary` (McpWire) failed only as part of the
  econnrefused cluster in runs 1/3 — no independent deterministic face.

## Standing

**PARTIAL_ALIVE** — all 3 runs executed and receipted verbatim on the shared tree;
classification executed vs F18–F23. Caveats disclosed: HEAD moved mid-session
(`014bb7a`→`efd8e1c`); run 3 ran on a post-fix tree with a foreign-modified
`azure_common_issues_test.exs`; enclave deterministic pair still OPEN.

## Cleanup

`_build-ft-v3` deleted after receipt (lane build root, cleanup law).

## Evidence commands

```
MIX_BUILD_ROOT=_build-ft-v3 mix test   # x3, logs /tmp/v3-soak-run{1,2,3}.log
grep -c "TimeoutError" /tmp/v3-soak-run{1,2,3}.log   # 0/0/0
grep -c "econnrefused" /tmp/v3-soak-run{1,2,3}.log   # 26/4/24
grep -c "store_churn\|not_a_dets_file\|needs_repair" /tmp/v3-soak-run{1,2,3}.log  # 0/0/0
just bench-machine
```
