# FINAL-RELEASE — v26.10.21 release seal

Standing of this document: **PARTIAL_ALIVE** — every claim below is
receipt-anchored; the honest remainder is enumerated in §8. Distinct from
the per-window wrap artifact (`FINAL.md` pattern): this is the canonical
release-seal document for the v26.10.21 window.

Context: solo · Date: 2026-10-21 (refresh 2026-10-22, BK-37) · Repo: /Users/sac/smalt

## 1. Executive summary

**The ERRC inversion.** This window inverted the generate-first default:
the wave opened with probes and audits (Explore wave over the ARD/PRD
charter, `ARD-PRD.md`) and every land was forced to buy its way in with a
court receipt. Deletion/tightening landed before generation: the
`ifMatchEtag` premise rot was *deleted* (KD-159 registers the SDK no-op;
CAS412 proved the real `accessCondition IfMatch` path — 800/800 412s);
PB-4's O(n) seal variant was *refuted* rather than landed (REFUTED-as-noise,
`receipts/pb4-merkle-dual-path.md`); the AMQP10 crash-only router audit was
typed **BLOCKED-UNSUPPORTED (SUBJECT_NOT_LANDED)** rather than laundered
(`receipts/amqp10-crash-only-skeptic.md`); GLD-5's skeptic killed the
"lossless converter" claim (F2 row loss, F3 formula injection, both OPEN)
instead of letting it seal (F2/F3 subsequently **CLOSED** by GLD-5FIX —
§5, `receipts/gld5fix-null-formula-court.md`). 45 validation cells, zero PENDING rows, and a
skeptic lane that owns the sharpest findings in the window — that is the
inversion evidenced.

**Two-engine architecture.** The window landed a second, parallel Erlang
engine beside the Elixir `Smalt.POWL2`/`PPlan` stack — `lib/smalt/pipeline/`
(`smalt_fond_plan.erl`, `smalt_fond_seal.erl`, `smalt_fond_powl_runner.erl`
gen_statem, 5-stage htn→fond→powl→ocel→seal) — and then differential-courted
the two engines against each other: PB-5 closed the correctness race (was
98/200 runner errors → 0/500 false positives) with 3-way Merkle receipt
byte-identity `AC94479A…AC3` through both seal paths; the cross-engine
graph court (`test/internal/powl2_graph_compat_court.exs`) is green on OTP
28 and 29 (8 tests, 0 failures under the 29.1.2 pin — `receipts/bk17-graph-compat-witness.md`). The seal gate is
IMPL-12-fenced: deterministic map-order only under a pinned toolchain
(sentinel phash2 == 628801; OTP 26.2.1 and 28.3 refuse with real binaries).

**Boundary certification at b253aa9.** Commit `b253aa991527100bd80d80ee75f0565f8aa57887`
(2026-10-21 16:35 -0700) is the prod-core boundary audit: the
smalt/duckdb separation holds at the code level; doc-comment interfaces
documented as boundary-surface adapters. `PROD-CORE-ADDENDUM.md` (+8 lines)
is the certification record. The SQL-ingestion wave (§5) sits entirely on
the CLI-adapter side of that boundary (real `duckdb` CLI via `System.cmd`,
stdlib-only converter, no in-VM engine coupling).

## 2. Validation ledger

Master board **v7** (`VALIDATION.md`, lineage v1 `dfe49a0` / v3 `7939df9` /
v4 45 cells → v5 GWS fold → v6 post-v5 wave fold → v7 BOARDV3 fold (BK-22);
counts re-read from the board's v7 Summary table + post-v7 row flips,
as-of 2026-10-22). Cell granularity = one
AR/PRD/NFR/migrate/bench requirement = **45 cells**, counted once at
primary row verdict.

| Verdict bucket | Count |
|---|---|
| ALIVE / PASS / CONFIRMED-on-pinned / ALIVE-on-pinned / AVAILABLE | 27 |
| PARTIAL / PARTIAL_ALIVE | 9 |
| REFUTED | 5 |
| UNSUPPORTED / FAIL | 4 |
| Row-level PENDING / PENDING-PB | 0 |
| Row-level PENDING-GWS (v5's 4 → v6's 2 → **0**: GWS-SANDBOX-GATES closed ALIVE-on-stub by WASM-1, GWS-DETERMINISM closed PASS by GWS-12, GWS-IN-WASM-COURTS closed PASS by BK-31 `receipts/bk31-gws14-inwasm-courts.md`, GWS-SEC-FUZZ closed PASS by BK-32 `receipts/bk32-gws15-sec-fuzz.md` — 1,172 hostile frames, 0 panics/traps/hangs) | 0 |

Bucket arithmetic 27+9+5+4 = 45 (v5's 26+10 became 27+9 via the single
v6 flip, AR-OBS-04 PARTIAL → ALIVE on OBS4COURT). Note on counts: the
board carries **5** REFUTED (one of them favorable — POWL-PERF), and
**4** UNSUPPORTED/FAIL.

The REFUTED cells, each with its probe:

- **AR-CORE-02** priority alias head injection — `p8_arcore02_drain.escript`
  3 legs: priority accepted on 28.3.1 identically to 29.x; ≤500 µs gate
  fails on every release.
- **AR-CORE-03** JIT multi-segment binary matching ≥30% — re-adjudicated on
  the pin by `receipts/impl13-jit-2912.md`: 1M mixed-endian decodes min-of-5,
  612 vs 695 ms (**11.9%** in favor of 29.1.2), reduction counts
  byte-identical (131,001,116) — real but under the ≥30% ARD gate.
- **AR-WIRE-03** strict generators `<-:-` + compr_assign —
  `p10_wire_ca.erl`: syntax error on 28.3.1 / 29.0.6 / 29.1.1; compr_assign
  is plain Erlang already.
- **AR-POWL-PERF** — REFUTED *favorably*: operator estimate 15–40 µs per
  native op refuted by `tmp/bench/powl-native-face.jsonl` (p99 **2 µs**
  point-read, 895k ops/s; CAS p99 5 µs).
- **AR-POWL-PB4** ReceiptEngine dual-path — `receipts/pb4-merkle-dual-path.md`:
  fingerprint-gated O(n) variant byte-identical but **not faster** (76.5 vs
  64.7 ms at n=10k); current sorted-tuple path stands.

The UNSUPPORTED / FAIL cells, each with its probe:

- **AR-CORE-04** escape analysis — no observable API, no profiling court.
  Flip: tprof call_memory court with >0% delta across toolchains.
- **AR-SEC-03** CRL `allowed_hosts` SSRF fence — zero CRL-fetch code in
  `lib/smalt`; airgap witness `tmp/bench/scvd-airgap.jsonl`.
- **AR-POWL-01** EEP-79 native records — `p3_eep79.escript`: forms rejected
  on 28.3.1 AND 29.1.1. (IMPL-23 found the adjacent EEP-78 feature real:
  multi-element comprehension templates compile on 29.1.2 —
  `receipts/impl23-eep78-probe.md`.)
- **NFR-FOOTPRINT** cold start — `receipts/t47-release-boot-gate.md`:
  release boots and serves real ops, but ≤500 ms ceiling **FAILED — best
  quiet-machine cold boot 1906 ms = 3.8x the ceiling** (RELCUT
  `receipts/relcut-deferred-listeners.md` landed the front-door 24%-earlier
  reduction; idle sub-claim UNSUPPORTED pending a stationary sampler).

GWS wave (v5 fold, v7 status): row-level PENDING-GWS is **0** —
GWS-SANDBOX-GATES closed ALIVE-on-stub by WASM-1
(`receipts/wasm1-otp29-sandbox-port.md`, 6-gate court, stub
caveat: `graphlaw_duckdb.wasm` does not exist); GWS-DETERMINISM closed
PASS by GWS-12 (`receipts/gws12-cross-engine-determinism.md`);
GWS-IN-WASM-COURTS closed PASS by BK-31
(`receipts/bk31-gws14-inwasm-courts.md`: 4 suites / 11 tests green on a
real wasmi Engine hosting the freshly built `graphlaw_wasm.wasm`;
typed caveat: frozen-duckdb-under-wasmtime stays open as the GWS-2
`-lduckdb` gap); GWS-SEC-FUZZ closed PASS by BK-32
(`receipts/bk32-gws15-sec-fuzz.md`: 1,172 hostile frames vs the real
wasm guest via the hostile `gl_call` ptr/len path — 0 panics/traps/hangs,
every refusal typed, refusal histogram Unsupported 654 / EngineRejected
291 / ResourceLimit 195 / NotSemanticContent 28 / ok:true 4); wave
evidence in `_LANES.md` GWS-1..12; rows flip only on their own receipts.

### Post-v6 landings (ledger additions, all receipted)

- **GLD-5 F2/F3 CLOSED** (`receipts/gld5fix-null-formula-court.md`,
  ALIVE): typed NULL sentinel (`csv_field(:null)` → bare `\N`, empty →
  quoted `""`, literal `"\N"` VALUE force-quoted — three distinct tokens,
  lossless under `read_csv(nullstr='\N', allow_quoted_nulls=false)`);
  formula neutralization with numeric-literal exemption (`-0.0`, `3.10`,
  `1e-3`, `+1` byte-exact; 7 formula payloads prefixed); value-exact
  round-trip court 6/6 rows inside real duckdb v1.4.1, 0 errors, zero row
  loss; F1 pin fenced (`{:injection_token, "t;"}`). The 2
  sql_ingest_wire_court failures in the receipt are pre-existing
  (another lane's in-flight `egress_router.ex`), HEAD==fixed verified.
- **GLD-6 row-gate security court** (`receipts/gld6-sql-row-gate-security-court.md`,
  ALIVE): `Smalt.GraphLaw.SqlRowGate` gates the DATA itself — DDL→SHACL
  auto-shapes via SqlShapeGen + the substrate's own `ShapeFile.parse!/2`,
  per-row refusal (NOT NULL→sh:minCount, datatype→sh:datatype, unknown
  column→sh:closed), untyped DDL refused by table.column, wired before
  OCEL projection (refused dump projects NOTHING). Court **7/7 PASS, two
  seeds** (456741 / 99) on the live wire face (real Bandit TCP + :httpc,
  no mocks).
- **GLD-7 ingest→governance→execution chain** (`receipts/gld7-ingest-to-settlement-court.md`,
  ALIVE): dump bytes → COPY parse → OCEL envelope (13 events / 13
  objects, 0 dangling) → shape admission → GL-2 LawCompiler guard →
  executed ANDON/settled sets == law-predicted sets (partition is
  law-derived, not fixture-asserted — tightened law refuses 6). **112/112
  `ok` assertions, exit 0.**
- **GLD-1 N3-over-SQL court** (`receipts/gld1-sql-n3-court.md`, PASS):
  one sha-pinned pg dump (`c5c65bd1…eed1990`) → duckdb CLI ingest → CSV
  projections → N3 forward-chaining fixed point over {s,p,o} triples →
  exact partition equality vs independent Elixir re-derivation, **three
  consecutive runs, two processes, identical** (r7 escalated chain
  consumes only rule-derived facts; r5 honestly empty on corpus, both
  legs agree).
- **SQLD-4 mapping DSL** (`receipts/sqld4-sql-mapping-court.md`, ALIVE):
  `Smalt.SqlIngest.Mapping` Turtle DSL (event/object/rel roles, rel rows
  double as object observations), `shacl_gate/1` fail-closed on the
  mapping itself, `project/2` enforces referential integrity via
  `Ocel.validate_envelope/2`. Court **12/12, 3 consecutive green runs**.
- **Guard-form arbitration settlement** (`receipts/sk5-sk3-credit-arbitration.md`,
  ALIVE): coordinator ruling — SK3's enforced-100 credit law canonical
  (typed `{:amqp10_link_credit_exhausted, handle, id}` at the 101st
  transfer, observable post-fix; `dispositions == 100` exactly, the
  `UNOBSERVABLE` dead-path branch removed); SK5's 2000-row pin (which
  predated the enforcement fix) re-pinned to the enforced-credit
  contract with bounded-window growth preserved. No `lib/` changes
  (65+/31− in one test file).
- **BENCH-12 cross-language denominator table** — landed as the §3
  fence table (`bench/README.md`, values re-read from on-disk artifacts,
  AR-BENCH-01 model).
- **POWLBENCH fresh re-run + adversarial leg** (`receipts/powlbench-fresh-rerun.md`,
  PARTIAL_ALIVE, BK-5): native face reproduces the regime
  (point-read p99 4 µs, CAS p99 6 µs, 0 errors, n=10000 each); 4-step
  settlement reproduced p50/p95 (29/77 µs) but **p99 373 µs (max 12.4 ms
  outlier) exceeds the AR-PROD-05 ≤100 µs gate and the 200 µs falsifier
  on the fresh run** — typed as machine-load tail (concurrent lanes live;
  n=200 coarse p99); the mutant 2×-step leg is non-vacuous (p50 29→113 µs,
  3.9x). AR-PROD-05 "within gate" rests on the earlier 74 µs p99 run
  until a quiet-machine re-run (`just quiet-check`) re-adjudicates.
- **TTV-7 warmed-P99 standard** (`receipts/ttv7-warmed-p99-standard.md`,
  PARTIAL_ALIVE, falsifier FIRED): burn-in mandatory, dual COLD/WARM
  profiles, reductions primary / wall-clock secondary with load context.
  Under load-132 on 16 cores the warmed tail did NOT collapse
  (warm p99 197 ms) while p50/p95 (6–7/42 µs) and reductions (285.4/step,
  drift 0.073%) stayed stable — the ms-tail is load-class, not cold-start
  and not governance regression; tail status UNRESOLVED-under-load,
  quiesced re-run owed before any sub-10 µs tail claim. Standard landed in
  `BENCH-ERLANG.md` § Warmed-P99 standard.

## 3. Measured denominators (the fence table)

The cross-language denominator table (`bench/README.md`, BENCH-12
deliverable; values re-read from on-disk artifacts, AR-BENCH-01 model,
ratio fences per `docs/NO_SLEEP_DOCTRINE.md`):

| plane | Elixir-harness number | pure-Erlang court number | verdict |
|---|---|---|---|
| cosmos point-read | T43 wire p99 0.813–1.04 ms fence | p99 0.543 / 0.672 ms, 10k ops x2 runs, 0 errors (`tmp/bench/court_bench_cosmos.jsonl`) | PARITY (2x fence ≤2.08 ms) |
| amqp frame decode | 254.3 reds/frame (IMPL-13/17) | 254.5 reds/frame, 1.05 µs/frame, 0 errors (`tmp/bench/court_bench_amqp.jsonl`) | PARITY (Δ 0.08%) |
| powl orchestration | PB-2 ≈17.5k reds/8-step (≈1,609/step); PB-5 gate A caller-side 239.31 vs 964.31 reds/step | BENCH-5 45,182.7 total-work reds/4-step (≈11.3k/step), p50 0.305 ms (`tmp/bench/court_bench_powl.jsonl`) | TYPED DIVERGENCE (accounting scope) |
| json decode | IMPL-16 134.2 ms min-of-5, 205.5 MB corpus | BENCH-6 SAX 80 ms min, 52.7 MB, peak heap 38,504 B, gates PASS (`tmp/bench/court_bench_json.jsonl`) | TYPED DIVERGENCE (corpus/mode) |
| governance tax (GL-9) | 47.24 reds/step, 0.25 µs/step | none | TYPED DIVERGENCE — PENDING-BENCH-2 |
| actor ceiling | n/a (pure-Erlang plane) | 17.65–60.12 reds/round-trip, n=1k→32k (`tmp/bench/court_bench_ceiling.jsonl`) | n/a — baseline |

BENCH-ERLANG contract status (`BENCH-ERLANG.md` §Status): AR-01/02/03
LANDED; AR-04 PARTIAL (self-court landed, seeded-perturbation shim-court
owed); AR-05 PENDING-BENCH-1 (escript runner, 20-min bounded poll
negative); AR-06 NOT STARTED.

P99-measurement law (TTV-7, `receipts/ttv7-warmed-p99-standard.md`): every
wall-clock p99 quoted against this table is burned-in/dual-profile
(COLD+WARM), with **reductions as the primary denominator** and load
context recorded; the §3 numbers above are reductions-based and stand
unchanged under the standard. Warmed tails breaching under load are
recorded real, never excused (TTV-7's own falsifier fired: warm p99
197 ms under load-132 — see §2).

## 4. PB wave results

All six PB receipts landed (`receipts/pb1-fond-loop-latency.md` …
`pb6-dual-boundary.md`); PENDING-PB resolves to zero.

- **PB-1 FOND loop** — PARTIAL_ALIVE. Native leg fully executed
  (contention 0→100%, 0→10 forced strong-cyclic retries/settlement, 0
  errors); DIV-1 resolved as **SDK-side premise rot**: `ifMatchEtag`
  appears zero times in @azure/cosmos 4.10.1 dist — the 1700/1700
  "accepted" witness never sent If-Match. CAS412
  (`receipts/cas412-cosmos-replace-if-match.md`, ALIVE) proved the wire
  surface: 800/800 stale replaces → 412 via real `accessCondition`; stale
  412s now etag-carrying; CAS412R regression 35/35
  (`receipts/cas412r-postfix-regression.md`).
- **PB-2 reductions denominator** — PARTIAL_ALIVE
  (`receipts/pb2-reductions-denominator.md`; cross-language context in
  the BENCH-12 denominator table, `bench/README.md` §per-plane table =
  §3 above): ≈**17.5k reductions per
  8-step settlement orchestration**, per-step divider ≈1,609; variance
  <0.1% over 5 runs; dominance finding — record+seal (15,224) ~9x the
  scheduling/HTN/graph work combined (2,320).
- **PB-3 executor ceiling** — PARTIAL_ALIVE
  (`receipts/pb3-executor-ceiling.md`): ramp 64→8192 real DETS, **0 errors
  at every rung, wall unreached at L8192** (2x past the wire face's clean
  ceiling); honest decay typed beyond ~L2048 (22.8k→3.8k ops/s, latency
  plateaus ~200–240 ms scheduler-queueing).
- **PB-4 Merkle dual-path** — REFUTED-as-noise (see §2).
- **PB-5 cross-engine differential** — ALIVE
  (`receipts/pb5-crosslang-differential.md`): n=200/engine 0/200 errors
  both; receipt byte-identity TIE (3-way Merkle `AC94479A…AC3`); executor
  ahead 5.4x throughput (11,426 vs 2,118 ops/s); correctness race closed
  (98/200 → 0/500 false positives); promotion ineligibility lifted,
  promotion not executed.
- **PB-6 dual-boundary walk** — ALIVE (`receipts/pb6-dual-boundary.md`):
  same 5-step settlement through real SDK over the TLS twin (N=300) and
  native ChangeFeed (N=5000); per-step tax lease +0.708 ms (9.7x), CAS
  +0.675 ms (12.6x), observe **−1.630 ms (0.3x, CDC drain beats
  point-read)**; HTTP/1.1-over-twin decomposition typed.
- **FONDRUNNER** (`receipts/fondrunner-otp29-pipeline.md`) — ALIVE: the
  two-engine family itself, 7/7 courts, 3 consecutive byte-stable runs.

## 5. The SQL-ingestion answer (SQLD/GLD waves)

The window's answer to "can SQL-shaped operational data enter the
governed substrate without changing the governed outcome":

- **Three source formats, one governed outcome.**
  - pg_dump COPY → `receipts/sqld2-sql-ingest-court.md` (PASS): real
    duckdb CLI v1.4.1, deterministic 500-row corpus (sha256-pinned
    generator, two runs byte-identical), 500 typed rows loaded,
    referential+domain integrity 0 violations; OCEL v2 projection
    80 events / 420 objects / 380 rels, 0 dangling.
  - SQLite db → `receipts/sqld3-sqlite-ingestion-court.md` (PASS): via
    duckdb `sqlite_scanner` (name recorded — not `sqlite`); 60 objects /
    900 events, byte-stable corpus digest; typed SKIP exit 3 if the
    extension is absent.
  - SQL INSERT dump (cold-chain seed) → `receipts/gld4-sql-seed-court.md`
    (PASS): **SQL in → byte-identical OCEL corpus → identical
    quarantine/release partition** to COLD-1; source-neutrality witnessed
    across two identical consecutive runs; N3 admission unchanged.
- **Mapping / shape layer.** `receipts/sqld5-sql-shape-gen.md` (ALIVE):
  `Smalt.GraphLaw.SqlShapeGen` projects duckdb DESCRIBE shapes to SHACL
  Turtle in the GL-2 law-compiler grammar, round-tripped through the
  substrate's own `ShapeFile.parse!/2`; unmappable types are typed
  `ArgumentError`, never silent widening. Court 14/14.
- **N3 governance face.** GLD-4's admission runs through the same N3
  governance as the fixture-born corpus — the governed outcome does not
  move with the ingestion path.
- **Wire face / CDC design.** `receipts/gld2-cdc-court.md` (PASS): the
  GLD-2 three-part CDC pattern (epoch snapshot = pure left-fold ledger;
  append-only delta log with `update_before`/`update_after` pairs and
  tombstoned deletes; court with exact-delta, idempotency, durability,
  tamper legs) — duplicated epochs and re-applied deltas yield identical
  ledger digests (100→115 rows across 145 events, no phantoms).
- **Perf baseline.** `receipts/sqld8-ingest-baseline.md` (PASS): 100k-row
  pg COPY dump, min-of-3, AR-BENCH-01 model — converter route 1545 ms /
  **64,725 rows/s** / 280.6 MiB peak RSS; direct CSV route 222 ms /
  **450,450 rows/s** / 95.4 MiB; cross-route aggregate parity byte-exact;
  fences derived from the measurement, not invented.
- **Skeptic kills, then the closes.** `receipts/gld5-ingestion-skeptic.md`
  (SUSPECT — the honest verdict): F1 fail-open header skip FIXED mid-audit
  (the flip is the non-vacuity proof); F2 NULL/empty conflation row loss
  and F3 CSV formula injection were filed OPEN — and **both CLOSED by
  GLD-5FIX** (`receipts/gld5fix-null-formula-court.md`, ALIVE: typed
  `\N` sentinel + numeric-exempt `'` neutralization + value-exact 6/6
  court in real duckdb, zero row loss). P1 execution surface PASS-INERT
  (`FROM PROGRAM` has no target — nothing in a hostile dump is executed).
- **Downstream governance on the ingested data.** GLD-6 gates the rows
  themselves (7/7, two seeds); GLD-7 chains ingest→governance→execution
  with executed sets == law-predicted sets (112/112); GLD-1 proves N3
  fixed-point partition equality with an independent Elixir
  re-derivation over the same dump. The governed outcome does not move
  with the ingestion path — now witnessed end to end, not asserted.

## 6. KD scoreboard (canonical register `../v26.10.14/KNOWN_DIVERGENCES.md`)

Register grew KD-01..157 → KD-01..**160** this window. Window mints and
dispositions (all flips via `scripts/kd_flip.py`, receipt-gated):

- **KD-144..146** (blob ETag `0x…` formats, Put Blob empty-body) — minted
  2026-10-21 from the W32 conformance census; KD-144/145/146 OPEN.
- **KD-147..152** (cosmos system props + `_etag` GUID, KV secret
  201-create / id shape / api-version refusal, queue GUID request-id) —
  all **CLOSED-SIMULATED** on
  `../v26.10.20/receipts/fix3-kd147-152-witness.md`.
- **KD-157** (HTTP/2 twin reset-rate parity) — **CLOSED-SIMULATED**:
  shim landed + witness `receipts/bk20-kd157-witness.md`; post-restart
  falsifier clean (retry window 539–562 → 0 retries after restart,
  `receipts/bk6-kd157-h2-postrestart-witness.md`, which also re-ran the
  OBS-04 two-node court 4/4).
- **KD-159** (`ifMatchEtag` silent no-op — client guidance row) and
  **KD-160** (smalt 412 etag-carrying superset affordance) — minted
  2026-10-21 from CAS412's evidence; both OPEN (KD-160 by design until a
  typed pinion lands).
- **KD-142** (blob error envelope) — **CLOSED-SIMULATED** via the
  StorageError XML shim + witness `receipts/bk18-blob-error-contract.md`
  (was wrongly listed open in the pre-refresh draft of this section).
- **KD-79** (KeyVault vaultUri loopback-by-design) — **CLOSED-WITH-EVIDENCE**
  (BK-29): re-witnessed live on fresh vaults at HEAD plus an adversarial
  `localhost`-authority refusal leg —
  `receipts/bk29-kd79-close.md`.
- **KD-154** (SB topic/subscription PUT location validation) —
  **CLOSED-WITH-EVIDENCE** per the register status cell (BK-36 wave-row
  triage; covering shim KD-156-marked; receipt landing in flight —
  register cell is the authority).

**Open at window close (register census 2026-10-22, status-cell read over
all 157 rows): 17 non-CLOSED = 15 OPEN + 2 PINION** — registered, not
hidden, each with its owner/next action:

| Row | Surface | Status / next action (owner) |
|---|---|---|
| KD-05 | blob container DELETE (WORM) | PINION — immutable-WORM by design; 409 ContainerLocked is the blob-worm gate (K1 disposition) |
| KD-10 | KV createKey PUT /keys/:name | OPEN — fix-and-witness: land `put "/keys/:name"` in `lib/smalt/egress/KvRoutes.ex` with `# KD-COVERS: KD-10`, flip on a kid-naming PASS witness (BK-11 triage) |
| KD-14 | KV RS256 sign/verify shape | OPEN — fix-and-witness: restore standard RSASSA-PKCS1-v1_5 sign shape in the KV crypto path, `# KD-COVERS: KD-14` (BK-11 triage; divergence re-witnessed live) |
| KD-23 | ResourceGraph bare `where` | OPEN — fix-and-witness: extend `normalize_pipeline/1` (`lib/smalt/data_plane/resource_graph.ex:189`), flip on a PASS witness (BK-11 triage) |
| KD-75 | KV soft-delete routes | OPEN — routes landed 2026-10-17 (`egress_router.ex:723-752`, `../v26.10.16/receipts/kd13-kd75-softdelete-routes-witness.md`); witness/flip owed |
| KD-86 | SB send to never-created queue | OPEN — emulator-by-design candidate; may resolve as documented-constant |
| KD-88 | EH checkpoint-store pump warm-up race | OPEN — cold-boot race; triage receipt `../v26.10.20/receipts/kd88-triage.md` |
| KD-90 | affidavit wasm seal latency | OPEN — perf divergence, bench-pinned |
| KD-92 | ARM-container vs data-plane store split | OPEN — WORM ARM-bridge (I16/L2) not yet landed |
| KD-93 | cosmos no-filter + stale projection | OPEN — from c11 typed findings + R7 duplicate-dispatch disclosure |
| KD-101 | Event Grid delivery (air-gap remote-push) | PINION — permanent by design (K7 disposition) |
| KD-144 | Blob container ETag `0x…` format | OPEN — W32 conformance census mint; shim/witness owed |
| KD-145 | Blob Put Blob response body | OPEN — W32 mint; shim/witness owed |
| KD-146 | Blob blob ETag `0x…` format | OPEN — W32 mint; shim/witness owed |
| KD-153 | SB namespace PUT status (202 vs 200/201) | OPEN — spec-cited fix post-shim or typed pinion |
| KD-159 | `ifMatchEtag` client guidance | OPEN — client-guidance row; closes with SDK-side pinion/Doc advisory |
| KD-160 | cosmos 412 etag-carrying superset | OPEN by design until a typed pinion lands |

Closed since the previous draft of this section (moved out of the open
list, receipt-cited): KD-79 (BK-29), KD-142 (BK-18), KD-154 (BK-36),
KD-157 (BK-20/BK-6).

## 7. Toolchain migration record (OTP 28.3.1 → 29.1.2)

Pin: `popcorn_demo/.tool-versions` — `erlang 29.1.2` /
`elixir 1.20.4-otp-29` (`receipts/impl9-popcorn-otp29-pin.md`, ALIVE).
Scope: every ALIVE-on-pinned cell types under this pin; the host OTP-28
toolchain compile-refuses the same tree (IMPL-11's standing falsifier
witness). Every court re-run after the recycle:

- `receipts/impl19-pin-coherence.md` — 8-file pin diff, full tree compiles
  clean on 29.1.2, exit 0.
- `receipts/impl20-postupgrade-tiers.md` — wire-tier census **28/28** on
  the recycled OTP-29 beam (subject e426d7d, erts-17.1.1 confirmed via
  bounded poll).
- `receipts/impl21-postupgrade-sdk.md` — real-SDK witnesses **5/5,
  0 errors** (live pid 85369, ports 9443/9444/5672/5673 UP, never
  restarted in-lane).
- `receipts/cas412r-postfix-regression.md` — **35/35** on the recycled
  beam.
- `test/internal/powl2_graph_compat_court.exs` — replayed under the pin:
  **8 tests, 0 failures** (0.1 s; `receipts/bk17-graph-compat-witness.md`).
- `receipts/impl13-jit-2912.md` — JIT re-adjudication on 29.1.2 (11.9%
  wall gain, reductions byte-identical).
- `receipts/fondrunner-otp29-pipeline.md` — 7/7 courts, 3 byte-stable
  runs on 29.1.2.
- Hygiene on the new toolchain: lib warnings **94→66→0** on the target
  backlog (`receipts/impl19-warnings-census-top5.md`,
  `receipts/warn2-warnings-backlog-6-10.md`); window receipts law-clean —
  0 NO-CONTEXT / 0 SUSPECT after CTXFILL backfill
  (`receipts/ctxfill-receipt-flag-backfill.md`).

## 8. Honest open items (typed residuals)

1. **azidentity OAuth leg** — GOLEG closed the handshake residual (real Go
   1.23.4 client, 6/6 legs, R90/D52 does not reproduce,
   `receipts/goleg-tls13-client.md`); the full azidentity/azurerm
   auth-flow session (OAuth2 over the twin) remains unprobed. Also: go1.23
   does not export the negotiated group name.
2. **idle-RSS re-scope** — NFR-FOOTPRINT idle sub-claim UNSUPPORTED; needs
   a stationary idle-RSS sampler receipt.
3. **Cold-start ceiling** — T47 measured FAIL at 3.8x (1906 ms vs ≤500 ms);
   RELCUT's deferred-listeners reduction is landed (front door 24%
   earlier, court 3/3) but the ceiling miss stands; one-shot-deferral
   limitation typed.
4. **duckdb-in-wasm decision** — GWS-IN-WASM-COURTS closed PASS for the
   graphlaw surface (BK-31, `receipts/bk31-gws14-inwasm-courts.md`) and
   GWS-SEC-FUZZ closed PASS (BK-32, `receipts/bk32-gws15-sec-fuzz.md`);
   the remaining open surface is the **frozen-duckdb-under-wasmtime link**
   (GWS-2 `-lduckdb` gap; `graphlaw_duckdb.wasm` does not exist) — the
   in-VM-vs-CLI-adapter decision stays unmade until that surface
   receipts.
5. **BENCH residuals** — PENDING-BENCH-1 (`erlang_bench.escript`, AR-05)
   and PENDING-BENCH-2 (GL-9 pure-Erlang court leg); AR-BENCH-04's
   seeded-perturbation shim-court; AR-BENCH-06 CI fences not started.
6. **Board residuals** — PB-1 SDK-leg rerun with real `accessCondition*`
   options; DATA adoption gaps (ARD CAS gate, ordered_walk, Registry.lock
   redesign, PartitionSupervisor wiring); NFR-LATENCY blob-PUT receipt +
   cosmos p99 outlier + the TTV-7 quiesced warmed-p99 re-run;
   PRD-APIM dedicated receipt at wrap; PB-5 promotion not executed;
   KD-159/160 pinions owed. (OBS-04 peer court closed — OBS4COURT
   `receipts/obs4court-peer-two-node.md` + BK-6 re-run 4/4; KD-157 flip
   landed — BK-20/BK-6.)

Closed this session, kept for the record: **GLD-5 F2/F3** — CLOSED by
`receipts/gld5fix-null-formula-court.md` (typed NULL sentinel, formula
neutralization, value-exact court 6/6, zero row loss); no longer an open
residual.

## See Also

- `docs/jira/v26.10.21/VALIDATION.md` — master validation board v7
- `docs/jira/v26.10.21/ARD-PRD.md` — the requirement charter
- `docs/jira/v26.10.21/BENCH-ERLANG.md` + `bench/README.md` — bench
  contract + denominator table
- `docs/jira/v26.10.21/PROD-CORE-ADDENDUM.md` — b253aa9 boundary record
- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — canonical KD register
- `docs/jira/v26.10.21/DIRECTIVES.md` — standing falsification charter

---
*Addendum (BK-BMIR2, 2026-10-22): `tmp/bench/scvd-airgap.jsonl` cited above now has a byte-identical tracked mirror at `docs/jira/v26.10.20/bench/scvd-airgap.jsonl` (paired sha256 `6fb6bfa952bf…`); provenance `docs/jira/v26.10.20/bench/PROVENANCE.md`.*
