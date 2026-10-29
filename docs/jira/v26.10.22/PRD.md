# PRD-26.10.22-SOVEREIGN-CORE

Standing: OPERATOR-CHARTER — requirements accrue standing via Chicago courts + receipts.
Target release: v26.10.22 · Parent: v26.10.21 (board v7, 0 row-level PENDING) ·
Method: DFLSS/DMADV · Standard: Chicago-Complete / zero-PENDING gate · Date: 2026-10-21
See also: [SYNC-CHARTER.md](SYNC-CHARTER.md) (four-axiom implementation charter),
[ARMSTRONG-PLAN.md](ARMSTRONG-PLAN.md) (4-phase build plan).

Classification: Core Substrate Architecture & Domain-Blind Execution Contract.
Companion security law: private project names are mechanically gated (NFR-SEC-004 /
COURT-PRIVATE-TRIP); scrub landed at 404efe2, historical commit messages disclose the
old name (no history rewrite).

## 1. Executive Summary

v26.10.22 is a domain-blind deterministic substrate: zero domain tokens in `.ex`/`.erl`/`.ts`
(all domain semantics live in external `.ttl`/`.n3` law files), dual-plane compute
decoupling (OLTP actor journals mounted read-only by the external engine only after
`.seal` sentinels), a sovereign in-browser client tier (WASM reticle worker + IndexedDB
binary WAL + Merkle accumulator + batch sync over `smaltFetch`), and provenance by
construction (O(1) Merkle receipts: fixed 320 B sync token; 48-word/384 B pplan
seal term post-GAP-6a). The ERRC matrix and architecture diagrams
are as chartered; the full text lives in the operator's PRD (reference copy of record:
operator transcript 2026-10-21). This file is the tracked canonical statement of
requirements and gates.

## 2. Functional requirements (tracked; standing accrues via court receipts)

| ID | Requirement | Current standing (measured anchors) |
|---|---|---|
| FR-RET-001 | Domain-blind law ingestion | reticle loads pinned 14-op wasm (blake3 `cbc80f07…`); law-compiler compiles SHACL→guards (powl2 courts) |
| FR-RET-002 | Byte-0 sieve | ANDON refusal non-mutating (ja5 fail-fast court; powl2 guard courts) |
| FR-RET-003 | SESE-POWL acyclicity | compile-time cycle refusal (fond runner court: adversarial cyclic plan crashes) |
| FR-CLI-001..005 | Console WASM worker / byte-0 refusal / IndexedDB WAL / Merkle accumulator / smaltFetch-only | **SYNC-2 lane in flight** (codec/worker/engine/page per operator reference; ws-lint/ws-build/ws-court gates) |
| FR-SNC-001..006 | Batch endpoint, 41-byte header, seq monotonicity, CRC32-C, fast-forward Merkle, join gate ω | **SYNC-1 lane in flight** (receiver + 5-gate court); FR-SNC-005/006 (fast-forward + join) = follow-up WOs |
| FR-SVR-001 | Wire parity | KD register conformance sweep this window (Blob/Cosmos/SB rows closing) |
| FR-SVR-002 | 16-bucket partitioned store + heirs | **TTV-5 lane in flight** (heir+adoption, gate: bucket-4 crash ≠ bucket-5 impact) |
| FR-SVR-003/004 | WAL sink + .seal rotation | SJ-1 court ALIVE (fsync→rename→meta→seal, 5 legs) |
| FR-SVR-005 | Cold replay before listeners | TTV-4 ALIVE (replay-then-listen init, kill court 4/4) |
| FR-SVR-006 | Dynamic atom elimination | JA-R3 landed; falsifier: 50k junk tokens Δatoms≡0 |
| FR-LAK-001..004 | Decoupled lakehouse / sentinel mounting / SIMD / statutory export | PROD-CORE-ADDENDUM boundary audit + GWS-12 cross-engine byte-identity; sqld8 450,450.5 rows/s measured |

## 3. NFR anchors (measured, not asserted)

| ID | Requirement | Measured anchor |
|---|---|---|
| NFR-LAT-002 | CAS p99 ≤5µs | native CAS put-if-match p99 5µs / 383,186 ops/s (`tmp/bench/powl-native-face.jsonl`) |
| NFR-LAT-005 | Sieve ≤0.50µs + ≤60 reds/step | 0.25µs median / 285.5 reds/step drift 0.073–0.154% (GL-9 + TTV-7 receipts) — reds-leg MET; wall-clock leg gated on quiescence (TTV-7b BLOCKED-ON-QUIESCENCE) |
| NFR-DUR-001 | Zero committed-key loss | TTV-4 kill court: 100% survive via replay |
| NFR-DUR-002 | Cascade ≤1.0ms | JA-7 crash-only court (`../v26.10.21/receipts/ja7-crash-only-court.md`, ALIVE): 10 crash-recover cycles, cascade ms measured `1 0 0 0 0 0 0 0 0 0` — ≤1ms every cycle, 0ms in 9/10; closure receipt `amqp10-court-closure.md` PASS ×2 |
| NFR-DUR-003 | Cold boot ≤2,000ms | TTV-6 re-typed ceiling, falsifier named |
| NFR-SEC-001 | Δatoms ≡ 0 @100k hostile | atom fence in ja5 court; JA-R3 falsifier |
| NFR-SEC-002 | Cert fail-closed observable | JA-R3 D2 (Logger.error on 4 branches) |
| NFR-SEC-003 | 16MiB/64MiB sandbox ceilings | GWS-11 measured boundary map |
| NFR-SEC-004 | Private-token gate | **NEW WO** — COURT-PRIVATE-TRIP: repo-tree scan gate (scrub precedent 404efe2) |
| NFR-EVI-001 | O(1) receipt (two surfaces) | sync token: fixed 320 B at every n (BK-92 cross-mint, layout-pinned); pplan seal term: 48 words = 384 B at n=10..10^5 post-GAP-6a (PB4-R re-run; was 40 words pre-GAP-6a) — bkrsize-receipt-truth |
| NFR-EVI-002 | Cross-engine byte identity | GWS-12 court |
| NFR-LAT-001 | Local write p99 ≤10µs | SYNC-2 gate (browser-side measurement court) |

## 4. Court matrix (each = fail-closed, exit-0 gate + receipt)

Refreshed 2026-10-22 (lane BK-PRDR): every cell cites a receipt path re-read
from disk, `[ -f ]`-verified, standing quoted from the receipt's own line;
provenance receipt `receipts/bkprdr-prd-matrix.md`. Prior in-flight
annotations removed where the gate has since landed — the VALIDATION.md
board (v1 + BK-SECPEND/BK-VCOURTS re-types) is the register of record.

| Gate | Charter anchor | Standing | Evidence (receipt + standing on disk) |
|---|---|---|---|
| COURT-STORE-REPLAY | FR-SVR-005 cold replay before listeners | ALIVE — kill court 4/4 | `../v26.10.21/receipts/ttv4-journal-boot-replay.md` |
| COURT-STORE-PART | FR-SVR-002 16-bucket partitioned store | PARTIAL_ALIVE — TTV-5 lane; BK-69r reconciled | `receipts/bk69r-store-reconciliation.md`, `receipts/store4-partition-court.md` |
| COURT-BOOT-REBIND | NFR-DUR-003 warm restart | ALIVE — consolidated court `just bkvc-court` leg 1 (TTV-4 warm-restart replay 4/4), ×2 exit 0 | `receipts/bkvc-consolidated-courts.md`; parent `../v26.10.21/receipts/ttv4-journal-boot-replay.md` |
| COURT-PRIVATE-TRIP | NFR-SEC-004 private-token gate | PARTIAL_ALIVE → remediated ALIVE | `receipts/bk50-private-trip.md` (honest RED) → `receipts/bk54-private-trip-remediation.md` (GREEN); `scripts/private_trip.py` + `just court` wiring on disk |
| COURT-ATOM-CLAMP | NFR-SEC-001 | PASS — named consolidated court (`just bkvc-court`, `justfile.d/51-bkvc.just`); atom-clamp leg re-observes JA-R3 D1 law on real `:atom_count` state, `Result: 7 passed` ×2 exit 0 | `receipts/bkvc-consolidated-courts.md`, `receipts/bksec-nfr-closures.md` |
| COURT-CERT-OBS | NFR-SEC-002 | ALIVE — both D2 faces witnessed on real certs (accept + missing-`ca_certfile` Logger.error/typed refusal); court found+fixed a real cert-mint defect (RSA modulus/exponent swap) | `receipts/bkvc-consolidated-courts.md`, `receipts/bksec-nfr-closures.md`, `../v26.10.21/receipts/ja-r3-ja16-defect-fixes.md` |
| COURT-SYNC-FASTFWD / COURT-SYNC-ANDON | FR-SNC-005/006 | UNBUILT (typed honestly): fast-forward Merkle sync and join gate ω have zero implementation; sync-specific andon legs do not exist. Owner: SYNC follow-up WO per PRD §5 | falsifier+greps embedded in `receipts/bkvc-consolidated-courts.md` |
| COURT-MERKLE-O1 | NFR-EVI-001 | PARTIAL_ALIVE — pb4 O(1) evidence exists, named standalone court pending | `receipts/pb4r-identity-court.md` + `receipts/bkrsize-receipt-truth.md` (re-pointed from `../v26.10.21/receipts/pb4-merkle-dual-path.md`, REFUTED-as-noise; BK-PRDA F1) |
| FR-SNC-001..004 | SYNC-1 receiver + 5-gate court | ALIVE — 11/11 court gates | `receipts/ath1-batch-frame-receiver.md`; auth `receipts/bk76-sync-auth-witness.md`; e2e `receipts/bk83-sync-e2e-auth.md` |
| FR-RET-001..003 | console worker tier | PARTIAL_ALIVE (browser surface ALIVE, sync server leg PARTIAL_ALIVE) | `receipts/ath2-nextjs-client.md`, `receipts/bk63-sync-interop.md` |
| FR-SVR-001 | wire parity KD register | ALIVE — register spans KD-01..KD-163+, final census CLOSED | `receipts/bk75-kd-final-census.md` |
| FR-LAK-001..004 | lakehouse sentinel mounting + cross-engine identity | ALIVE | `receipts/erl4r-vc-twins-lakehouse.md` |

### 4a. Post-matrix capability gates (landed without a PRD §4 row — added)

| Gate | Capability | Standing | Evidence |
|---|---|---|---|
| COURT-WPS-SUBPROTO | Web PubSub subprotocol echo (KD-166) | ALIVE — fix landed + real-wire witness, close condition met (`sec-websocket-protocol: json.webpubsub.azure.v1` echoed in 101) | `receipts/kd166-witness.md` (falsifier, NOT-ALIVE) → `receipts/kd166-fix-witness.md` (GREEN); face `receipts/az5-webpubsub.md`, `receipts/az5b-webpubsub-receipt.md` (ALIVE) |
| COURT-MHSM-FAILCLOSED | MHSM non-list constraint fail-closed + DTDL cyclic-extends refusal (EXPL5-T1/T2) | ALIVE — repairs landed with real court `test/internal/expl5r1_court_test.exs` | `receipts/expl5r1-t1t2-repairs.md` (ALIVE); policy face `receipts/az4b-mhsm-receipt.md` (ALIVE policy face / typed UNSUPPORTED for FIPS-level hardware isolation — no HSM silicon at loopback) |
| COURT-KFK-RECCOUNT | Kafka recordsCount cross-check — silent tail-drop closed (`{:error, :record_count_mismatch}`, typed, never partially admitted) | ALIVE | `receipts/kafka-exp4-repairs.md` (ALIVE) |
| COURT-SAS-HOSTSCOPE | SAS verifier `sb:` audience host-scoping (KD-172) | ALIVE — wildcard tightened to host-scoped match (`# KD-COVERS: KD-172`), closed | `receipts/kdsasv-audience-row.md` (PARTIAL_ALIVE registration) → `receipts/kd173r-audience-repair.md` (ALIVE) |
| COURT-INGEST-HMAC | BFF `/api/v1/ingest` HMAC sig gate (`x-smalt-signature`, `timingSafeEqual`) + dev-default-key posture KD-173 | ALIVE — census + live probes on a real Next dev server; KD-173 registered OPEN (dev-default credential posture) | `receipts/bkbffsec-census.md` (ALIVE), `receipts/expl7r1-bff-repairs.md` (ALIVE — shared-secret/HMAC caller gate landed) |
| COURT-DEBUG-FACES | Gated debug faces (`SMALT_DEBUG_FACES`) vs N-lane harness | ALIVE | `receipts/bknenv-debug-faces.md` (ALIVE) |
| COURT-CLI-SURFACE | smalt-cli surface post-5-wave repairs (EXPL12-R/C/D/W + EXPL12-B): login/profile, storage `--immutable` WORM ANDON, `-n` az-parity flags, `arm_request` tokenless→STS→bearer handshake, monitor endpoints/metrics/ocel-tail | ALIVE — consolidated verify on the fully-merged tree: py harness 149+2 skipped (all), 37 (`-m anonymous`), 35+2 skipped (`-m enforce`), 102 (package lanes); cross-lane e2e on the live `:enforce` substrate composes all five waves, exit 0 throughout except the intended 409 WORM ANDON; pyright 1.1.409 on wire/profile/config/login/monitor/servicebus/storage = 0 errors | `receipts/bkcliv-final-verify.md` (ALIVE); wave receipts `receipts/expl12r-cli-fixes.md` (ALIVE), `receipts/expl12c-sb-name-flag.md` (ALIVE), `receipts/expl12d-sb-residual.md` (ALIVE), `receipts/expl12w-arm-handshake.md` (ALIVE), `receipts/expl12b-login-monitor.md` (ALIVE); honest typed residues: `receipts/expl12-cli-flag-parity.md` (PARTIAL_ALIVE), `receipts/expl12v-auth-uniform.md` (PARTIAL_ALIVE) |

Rows with no verifiable receipt: none — every cell above is receipt-backed;
unbuilt capability typed UNBUILT, not smoothed. (2026-10-22 lane BK-CLIROW:
COURT-CLI-SURFACE added — the Python smalt-cli surface had no §4 row; the
FR-CLI-001..005 row in §2 is the browser Console tier, a different surface.
Cell typed from the receipts' own standing lines, re-read from disk.)

## 5. Roadmap

- **Gate 0 hardening**: TTV-1/2/3 ✔ landed (JA-R3). COURT-ATOM-CLAMP/CERT-OBS
  named-court consolidation ✔ LANDED — `just bkvc-court` green ×2 (`Result: 7
  passed`, exit 0; `receipts/bkvc-consolidated-courts.md` ALIVE, owned-tier
  adjacency 33/33). Remaining Gate-0 WO: COURT-MERKLE-O1 standalone court still
  pending (§4 PARTIAL_ALIVE; pb4 evidence exists).
- **Gate 1 durability**: TTV-4 ✔; BK-33 rebind ✔ RESOLVED
  (`../v26.10.21/receipts/bk33-warm-restart-rebind.md`); TTV-5 partitioning
  court ALIVE (`receipts/store4-partition-court.md` 4/4 ×3) with BK-69r
  reconciliation — remaining Gate-1 WO: the named
  `test/integration/ttv5_store_partitioning_court.exs` receipt pairing
  (heir+adoption crash-isolation leg per §4 COURT-STORE-PART).
- **Gate 2 console+sync**: SYNC-1 batch receiver ✔ LANDED ALIVE
  (`receipts/ath1-batch-frame-receiver.md` 11/11; finish-and-relay
  `receipts/sync1-batch-receiver.md` ALIVE); SYNC-2 browser surface ALIVE
  (`receipts/ath2-nextjs-client.md`); FR-SNC-005/006 (fast-forward Merkle +
  join gate ω) remain queued WOs.
- **Gate 3 seal**: private-trip gate ✔ landed green
  (`receipts/bk54-private-trip-remediation.md` ALIVE). Remaining: witness-all
  full gated run (BK-44 recipe; `receipts/bk95-witness-full.md` attempt-1
  PARTIAL_ALIVE, reds typed, blocked on lane churn), HEAD court sweep full
  green (`receipts/bkseal-full-green.md` PARTIAL_ALIVE — stages green except
  typed census-fence residues on three lanes), FINAL-RELEASE-26.10.22.md
  flip, tag v26.10.22.

New WOs minted by this PRD — status: (a) named-court consolidation: ✔ LANDED
for COURT-ATOM-CLAMP/COURT-CERT-OBS (bkvc, ALIVE); COURT-MERKLE-O1 standalone
court still OPEN; (b) FR-SNC-005 fast-forward Merkle sync — OPEN; (c) FR-SNC-006
join gate ω — OPEN; (d) COURT-PRIVATE-TRIP — ✔ LANDED (bk50 RED → bk54
remediation GREEN, wired into `just court`).
