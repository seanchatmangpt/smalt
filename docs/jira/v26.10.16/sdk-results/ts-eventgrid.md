# SDK Lane TS — Real @azure/eventgrid vs smalt v26.10.16 (KD-39 witness cell)

Standing: PARTIAL_ALIVE — probe cell authored and green; the EG1-schema
refusal is the REGISTERED DIVERGENCE (KD-39), proven fail-closed on the real
wire, not a defect.

Date: 2026-10-16 · Lane: TS eventgrid (KD-39) · Probe:
`test/sdk-full/eventgrid.probe.mjs`

## Harness

- `@azure/eventgrid 5.12.0` (real npm wheel; added to
  `test/sdk-full/package.json` deps this lane) over the real HTTP wire.
- Lane-private substrate: `mix run --no-start --no-halt` (MIX_ENV=test,
  `MIX_BUILD_ROOT=_build-lane327`), ports 39311-39316 (exercised planes
  amqp=39311 / eventhubs=39312 / arm=39313; egress=39314, arm_tls=39315,
  mcp=39316 — the listeners the app unavoidably opens alongside them).
- Exit-code contract: 0 pass / 1 probe failure / 2 substrate never up /
  3 harness skip. This run: **exit 0**.

## Results

| probe | result | evidence |
|---|---|---|
| `eg.eg1-gridevent-schema-typed-unsupported` — EventGridPublisherClient ("EventGrid" input schema: id/subject/eventType/dataVersion, no specversion) → POST /topics/ts-eg-kd39/events | **DIVERGENCE (registered KD-39 / GAP(eventgrid-eg1-schema-absent))** — refused typed `400 InvalidCloudEvent`, body names the CloudEvents-1.0-only ingestion law ("Event failed CloudEvents 1.0 validation: specversion must be \"1.0\"…"); admission would falsify the registered divergence and the probe hard-FAILs on it | this run (exit 0) |
| `eg.cloudevents-1.0-admitted` — CloudEvent publisher → 200 empty body (real Event Grid form), then GET /topics/ts-eg-kd39/events returns the event | PASS | this run (exit 0) |
| `eg.hostile-cloudevent-400` — two-tier: (a) real SDK refuses a source-less CloudEvent client-side (payload serializer: `events.source cannot be null or undefined`) before any wire byte; (b) the same payload over the raw wire | PASS — server answers typed `400 InvalidCloudEvent` (all-or-nothing admission, no store) | this run (exit 0) |

Command receipt:

```
$ node test/sdk-full/eventgrid.probe.mjs
[ts-eg-probe] substrate up on 39311-39316 after 1505ms
PASS eg.eg1-gridevent-schema-typed-unsupported :: DIVERGENCE (registered KD-39): EG1 native schema (id=kd39-eg1-witness) refused typed 400 InvalidCloudEvent naming CloudEvents-1.0-only ingestion — fail-closed as pinned
PASS eg.cloudevents-1.0-admitted :: CloudEvent kd39-ce-1792167214101 admitted (200, empty body per real Event Grid form) and retrieved via GET (specversion=1.0, type=Smalt.Ts.KD39.CloudEvent)
PASS eg.hostile-cloudevent-400 :: tier(a) SDK client-side refusal ("Error \"events.source cannot be null or undefined.\" occurred ..."); tier(b) raw wire: hostile CloudEvent (missing source) refused typed 400 InvalidCloudEvent (all-or-nothing admission)
SUMMARY 3/3 probes passed
```

## Divergences

- **KD-39 (eventgrid, ts probe cell) — WITNESSED, remains the registered
  divergence.** Native Event Grid event schema (EG1, system-topic events) is
  not implemented; CloudEvents 1.0 admitted only; the refusal is typed
  fail-closed 400 and names the law. The probe's expected outcome IS the
  divergence: it asserts the typed refusal (and hard-FAILs if the server ever
  admits EG1), so the cell is a DIVERGENCE row in SDK_MATRIX terms
  (`parse_receipt` counts it as a divergence cell, not a failure).
- New TS-lane SDK-behavior note (not a server divergence): the JS SDK
  refuses a source-less CloudEvent client-side at payload serialization,
  so the server-side all-or-nothing gate is witnessed by a raw-wire tier in
  the same probe.

## Coordinator notes

- KD-39 row (docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:57, OPEN, "no probe
  cell (ts)") can flip to CLOSED-SIMULATED/witnessed per the standing
  kd_flip receipt-gated flow — witness receipt = this file (mtime >
  shim; no lib/ shim was landed this lane, probe-only).
- `scripts/sdk_coverage.py` eventgrid cell still declares `ts=[]` +
  `missing_kd={"ts": ["KD-39"]}`; the cell should pick up
  `ts=["eventgrid"]` once KD-39 flips (left to the coordinator — shared
  file).
