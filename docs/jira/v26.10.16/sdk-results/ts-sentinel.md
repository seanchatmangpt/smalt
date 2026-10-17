# SDK Probe Receipt: sentinel TS (KD-37)

- **Subject**: `test/sdk-full/sentinel.probe.mjs` (raw-wire node fetch; no first-party
  Azure Monitor DCR-ingestion/Log-Analytics-Query SDK exists for node — the pair is
  exercised over the real HTTP wire instead)
- **Date**: 2026-10-16
- **Lane**: 325 (`MIX_BUILD_ROOT=_build-lane325`)
- **Substrate**: lane-private self-boot, ports egress 39305 / arm 39306 / tls 39307
  (AMQP/EH tail 39308/39309, same lane lease), `MIX_ENV=test` (data plane
  `:anonymous`), spawned under `/tmp/smalt-substrate.lock` (lock fd closed on the
  node invocation)
- **Standing**: PASS
- **Result**: 9/9 probes passed, exit 0

## Coverage (Sentinel surface, lib/smalt/data_plane/sentinel.ex + egress routes)

| # | Probe | Verdict | Detail |
|---|---|---|---|
| 1 | DCR ingest 204 + `x-ms-request-id` (api-version 2023-01-01) | PASS | v4 GUID request id on the real wire |
| 2 | Ingest wrong api-version 2022-10-27 | PASS | typed 400 `InvalidApiVersion`, byte-pinned prose |
| 3 | Ingest absent api-version | PASS | typed 400 `InvalidApiVersion` |
| 4 | Ingest non-object record (null in batch) | PASS | typed 400 `InvalidData`, no partial insert |
| 5 | Query roundtrip (absent api-version — real SDK wire shape) | PASS | PrimaryResult, 2 rows, augmented columns `ledgerId`/`tenantId`/`subjectSha256`/`eventId`/`sha256Hash` present; both ingested witnesses returned |
| 6 | Query with api-version 2023-01-01 | PASS | 200 PrimaryResult |
| 7 | Query wrong api-version 2021-08-27 | PASS | typed 400 `InvalidApiVersion` (R173 / GAP D8 gate) |
| 8 | KQL pipeline `where \| project` | PASS | column order preserved, filter correct (1 row) |
| 9 | Bare operator without pipe | PASS | typed 400 `BadQuery` (R26 gate) |

## Embedded command output (excerpt, run 2026-10-16 09:5x PT)

```
[ts-sn-probe] substrate up (egress 39305, arm 39306) after 34085ms
[PASS] dcr-ingest: 204 + x-ms-request-id (api-version 2023-01-01) — status=204 x-ms-request-id=d9a1b143-650a-4bbc-bd7a-aa20d9594bff
[PASS] dcr-ingest: wrong api-version (2022-10-27) -> typed 400 InvalidApiVersion — status=400 code=InvalidApiVersion msg="api-version must be 2023-01-01"
[PASS] dcr-ingest: missing api-version -> typed 400 InvalidApiVersion — status=400 code=InvalidApiVersion (absent param)
[PASS] dcr-ingest: non-object record -> typed 400 InvalidData — status=400 code=InvalidData (null record refused, no partial insert)
[PASS] query: roundtrip ingested rows (no api-version — real SDK wire shape) — rows=2 cols=9 roundtrip ok (both witnesses present)
[PASS] query: api-version=2023-01-01 accepted — status=200 PrimaryResult rows=2
[PASS] query: wrong api-version (2021-08-27) -> typed 400 InvalidApiVersion — status=400 code=InvalidApiVersion (query route gate, R173)
[PASS] query: KQL pipeline where | project order preserved — pipeline where|project: 1 row (lvl==a), cols=[msg,n] in order
[PASS] query: bare operator without pipe -> typed 400 BadQuery — status=400 code=BadQuery (R26 parse-error gate)
SUMMARY: 9/9 PASS, 0 FAIL
```

## Divergence observations (KD candidates — rows NOT minted by this lane)

1. **Workspace-id / DCR-name coupling** (KD candidate for the sentinel register):
   `Smalt.DataPlane.Sentinel.query/2` lists stored rows under
   `"#{workspace_id}/"` while `ingest/4` stores under `"#{dcr}/#{stream}/"`, so a
   query only sees rows when the query workspace id EQUALS the DCR name. Real Log
   Analytics scopes query by workspace, independent of DCR. The probe pins the
   implemented contract (WS = DCR) and documents the coupling; it does not
   paper over it. Registered divergence cell basis: behavior is pinned by
   `test/compliance/c7_events.exs` (query "c7-dcr-q" after ingest "c7-dcr-q").
2. **`TimeGenerated` not materialized on ingest**: the emulator preserves the
   row's own keys and only lists `TimeGenerated` in the empty-result column set
   (`@base_columns`); real Log Analytics always stamps `TimeGenerated` on
   ingested rows. Surfaced as a probe finding mid-run (1 of 9 cells), probe
   corrected to assert the implemented behavior with the divergence recorded
   here.
3. **No first-party node SDK** for the DCR Logs Ingestion + Log Analytics Query
   pair — probe is raw-wire (fetch). Cell class: MISSING-REGISTERED (KD-37) is
   closed by this raw-wire witness, subject to coordinator KD edit.

## Replay

```bash
flock /tmp/smalt-substrate.lock node test/sdk-full/sentinel.probe.mjs
# lane-private variant: MIX_BUILD_ROOT=_build-lane325 SMALT_TSSN_EGRESS_PORT=39305 ... (defaults in file)
```

Exit codes: 0 pass / 1 probe failure / 2 substrate never up / 3 harness or lane-port occupied.
