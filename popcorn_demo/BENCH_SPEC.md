# BENCH_SPEC

Frozen-DuckDB compression/ingestion bench spec for OCEL v2 telemetry over
BEAM. Falsifier-first: this document makes NO capability claims — it names
what would count as death for each manifesto number, and the harness that
would run it IF/WHEN a compression backend exists in the testbed.

Manifesto referent status: `UNSUPPORTED` pending lane R1's artifact search.
Every numbered claim below starts `UNSUPPORTED`; nothing here flips that
without a closing receipt (see Section 5).

## 1. Corpus — what the lanes actually capture

All slices come from smalt's own substrate; no synthetic rows.

- **OCEL event log (primary)**: `lib/smalt/telemetry/ocel_ndjson.ex` —
  object-centric event log emitted as NDJSON. The lane boots a substrate
  via `bench_boot`, drives real traffic, and captures the raw NDJSON stream
  to `tmp/bench-ocel-<lane>.ndjson`. This raw stream is the compression
  BASELINE (byte count = denominator of every ratio).
- **Semconv telemetry events**: `lib/smalt/telemetry/semconv/` —
  `:telemetry` events fired by the data plane / AMQP handlers. Captured with
  a `:telemetry.attach` handler writing one line per event.
- **Substrate logs**: `tmp/*.log` from the `bench_boot` substrate — high
  cardiality free text (timestamps, pids, ports). Captured as a "messy"
  slice; expected to stress any columnar backend differently than clean
  OCEL rows.
- **AMQP message bodies**: real Service Bus / Event Hubs payloads replayed
  through the live substrate, captured to NDJSON with envelope metadata
  (lock tokens, delivery counts, partition keys).

Three slices, all captured on private ports under `MIX_ENV=test`,
auth_mode anonymous (port law: lane bN -> `39000+10N..+5`):

| slice | id | source |
|---|---|---|
| S1 clean-OCEL | `ocel-ndjson` | `ocel_ndjson.ex` stream under mixed blob/cosmos/queue traffic |
| S2 semconv | `semconv-events` | `:telemetry` attach over the same run |
| S3 logs+AMQP | `logs-amqp` | `tmp/*.log` tail + AMQP body replay |

Corpus is fixed and hashed (sha256 per slice) at capture time; the hash is
embedded in every result record so a ratio claim is replayable against the
exact bytes it was measured on.

## 2. Claims under test — exact numbers + typed falsifiers

Baseline for every claim = raw captured corpus bytes (Section 1), same
slice, same sha256. "1pp" = one percentage point of ratio.

- **C1 — "90% floor"**: ratio fence vs raw NDJSON baseline, same corpus;
  dies if measured ratio < 89% on 2 of 3 slices.
- **C2 — "94.93% @100k rows"**: ratio fence on the exact 100,000-row
  prefix of S1 and S2 (deterministic padding if a slice is short); dies if
  measured < 93.93% on 2 of 2 prefixed slices.
- **C3 — "97.01% @1M rows"**: ratio fence on the exact 1,000,000-row
  prefix of S1 (capture extends traffic until S1 carries >=1M rows); dies
  if measured < 96.01%.
- **C4 — "99.76% Fleet-D"**: dies UNCONDITIONALLY unless the manifesto's
  Fleet-D corpus is produced as an artifact (referent, lane R1) — smalt
  has no Fleet-D corpus; without it the claim is UNSUPPORTED, never
  PASS-by-analogy.
- **C5 — "12.16M rows/s ingestion"**: throughput fence — backend bulk-load
  of S1 (>=1M rows) vs sleep-free wall-clock baseline (NDJSON line-count /
  elapsed); dies if measured < 12.16M rows/s - 5%, and dies if any ingest
  path uses `Process.sleep`.

Falsifier execution rules:

- Each claim runs 3 times; median is the reported measurement, all 3
  embedded in the jsonl.
- A claim REFUTED on any fence is REFUTED — no averaging across slices to
  rescue it.
- The ingest path is a real bulk-load into the backend on disk (Chicago:
  real collaborator), not an in-memory counter.

## 3. No-sleep / ratio-fence law compliance

- All timing is wall-clock around real work; zero `Process.sleep` in the
  harness — `just sleep-gate` covers `popcorn_demo/scripts/` and the gate
  must stay green.
- Throughput fences are RELATIVE ratio fences against an independent
  sleep-free baseline measured in the same run (raw NDJSON line-count /
  elapsed), not absolute ms bounds — absolute ms fences hug the retry
  constant and flake (smalt FLAKE_LEDGER F8 class).
- Duration claims carry no fixed sleeps; readiness of the backend is a
  bounded poll on a real observable (file exists / row count reachable via
  query), deadline-checked, typed immediate-fail on unexpected shape.
- Stress tier shape (per `docs/STRESS/BOUNDS.md` conventions): a
  population-fenced stress body (`:stress` tag, excluded from plain runs)
  drives 10x corpus volume through ingest and re-checks C5's fence at
  volume; population fence asserts the stress corpus row count BEFORE the
  fence runs, fail-closed, so an empty corpus cannot read as a pass.

## 4. Harness location and lane conventions

- Is specified to live at `popcorn_demo/scripts/bench_compression.sh` (not yet landed; derivation receipts currently at `popcorn_demo/bench/`) (+ per-claim drivers
  `bench_compression_cN.py`), following `scripts/bench/` lane conventions:
  lane id `b30` family (SDK-surface band), port law `39000+10*30..+5` =
  `39300..39305`.
- Sources `scripts/bench/lib.sh`; substrate via `bench_boot b30`, results
  ONLY to its own file `bench/bench-compression.jsonl` via
  `bench_emit <file> <surface> <op> <n> <ops_per_sec> <p50> <p95> <p99>
  <errors>`; script uses underscore, result jsonl uses hyphen.
- Each result record embeds: claim id (C1..C5), slice id, corpus sha256,
  measured value, claimed value, fence, verdict (PASS/REFUTED/UNSUPPORTED),
  3-run raw values.
- `bench_boot`'s typed-timeout path (exit 124 on substrate-listen failure)
  is the loud skip — a skip is never recorded as PASS.

## 5. Standing vocabulary

Exactly three terminal standings for every claimed number, receipt-gated:

- **PASS** — a closing receipt exists: harness ran against a real backend
  artifact, all three runs cleared the fence, receipt embedded in
  `docs/jira/v<active>/receipts/`.
- **REFUTED** — the fence died on real measurement; the receipt records
  the numbers and the claim is retired (fix-forward, no re-laundering).
- **UNSUPPORTED** — no referent/backend artifact exists (lane R1's likely
  outcome). Claim stays UNSUPPORTED; no harness run can mint PASS without
  the artifact, and UNSUPPORTED is never silently upgraded.

Standing of THIS document: ALIVE as a spec. It receipts nothing about the
manifesto's numbers; every claim above is UNSUPPORTED until a receipt says
otherwise. Flips happen only via receipt, never by editing a claim's
wording.

## See Also

- `docs/STRESS/BOUNDS.md` (bounds-table + fail-closed conventions)
- `scripts/bench/lib.sh` (`bench_boot` / `bench_emit` contract)
- `docs/NO_SLEEP_DOCTRINE.md` (no-sleep law, ratio fences)
- `docs/jira/v26.10.19/FINAL.md` (receipt/standing conventions)
