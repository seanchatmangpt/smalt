# SCVD wrap receipt — v26.10.20 (terminal artifact for the SCVD PRD)

Standing: **ALIVE** — every artifact cited below was `ls`-verified on disk in
this session before citation; every cited receipt was re-read and confirmed
non-SUSPECT (`popcorn_demo/scripts/receipt_index.py` reports SUSPECT=0 over
the testbed store: receipts=33, NO-CONTEXT=23 — NO-CONTEXT is a header-format
parse artifact, not an output-less receipt; every cited receipt embeds real
command output, verified by re-reading each file). Author: milestone-doc lane
W28 (supersedes the W22-C revision). No GAP tokens minted; no KD rows
touched by this lane; no generated file hand-edited.

## 1. Harness — S1 engine, S6-audited

- Subject: `popcorn_demo/lib/popcorn_demo/concurrency.ex`
  (`PopcornDemo.Concurrency`, `ramp/1` + `contention/1`; three-state
  fail-closed contract `:verified` / `:environment_skip` /
  `:invariance_breach`; zero-egress by construction).
- S6 audit: F1–F3 (cosmos `@pk` param key, unmonitored-actor receive hang
  fixed with `spawn_monitor` + typed `{:actor_crashed, reason}` breach
  classification, `map_size/1` determinism verdict) — all three verified by
  execution, per `popcorn_demo/receipts/v261020-s1-concurrency-ramp.md`
  (standing ALIVE; fail-closed behavior exercised live: a pre-fix ramp(8)
  reported `breaches: 8, verified: 0` rather than coercing a pass).
- Host gate legs (post-F1–F3, standing numbers): ramp(16) verified=16
  breaches=0; ramp(64) verified=64 breaches=0;
  `CONTENTION64 {:ok, %{keys: 8, n: 64, winners: 8, losers: 56,
  committed_rows: 8}}`.

## 2. Tier verdicts — two subjects, never conflated

### 2a. Host BEAM subject (OTP 28/29 JIT)

Source: `popcorn_demo/BENCH_SCVD.md` + `popcorn_demo/bench/scvd.jsonl`
(109 rows at terminal state, re-counted this session via `wc -l` = 109;
46 pre-window rows clean, zero error rows, zero breaches, zero
`environment_skip`; the +63 are the W15-C `wave: "w15c-tail9"` rows, §5b).
Via `popcorn_demo/scripts/bench_scvd.sh` (verified on disk).

| tier | target | measured (worst PRD rung N=256, median-of-3) | verdict |
|---|---|---|---|
| Tier 1 | <500 ms / <16 MB | 6.02 ms / +1.2 MB ramp-attributable increment | PASS (83x / 13x margin) |
| Tier 2 | <750 ms / +24 MB | 6.02 ms / +1.2 MB | PASS (124x / 20x margin) |
| Tier 3 | <1200 ms / <32 MB | 6.02 ms / +1.2 MB | PASS (199x / 26x margin) |

### 2b. In-browser subject (wasm BEAM, headless Chromium, COOP/COEP)

| subject | target | measured (3 runs) | verdict |
|---|---|---|---|
| t256 wall | <1200 ms | 64.034 / 64.984 / 65.185 ms | PASS (~18x margin) |
| t256 leg law | all 256 verified, 0 breaches | held all 3 runs | PASS |
| c128 | 8 winners / 120 losers / 8 committed | `w8/l120/committed8` every run | PASS |
| main-thread heap | <32 MB | 10,000,000/10,000,000 B (~9.5 MiB) | PASS, quantized-class |

In-browser source:
`docs/jira/v26.10.20/receipts/scvd-browser-ramp-witness.md` (standing PASS,
3 witnessed runs, all exit 0, cooked bundle, headless Chromium
chrome-headless-shell 156.0.8078.4).

## 3. KD register status (regenerated from the canonical register)

Ground truth: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (rows KD-01..KD-134,
132 table rows, statuses re-parsed from the status column this session; the
table is ground truth, prose counts may lag). Class counts (this session's
parse):

| status class | rows |
|---|---:|
| CLOSED-SIMULATED | 74 |
| CLOSED-WITH-RECEIPT | 29 |
| CLOSED-OBSOLETE | 10 |
| CLOSED (other) | 2 |
| PINION (permanent-by-design) | 2 |
| OPEN | 15 |

(132 rows classified; the prior wrap's "unparseable KD-23 pipe-in-cell"
artifact is cured — commit 4c26019 fixed the status cell, KD-23 now parses
OPEN.)

### 3a. Key dispositions this window (verified against the canonical register)

- **KD-88** — OPEN, **client-bound**: server-side root REFUTED (W13-H witness
  `docs/jira/v26.10.20/receipts/kd88-attach-race-witness.md` — tables
  self-heal, attach served correctly 40 ms cold); remaining scope is
  client-side pump pre-send stall + the KD-129 codec lead; falsifier
  re-typed to the client surface.
- **KD-127** — CLOSED-SIMULATED (flipped since the last wrap): bounded
  redelivery sweep landed (commit b72db95), post-shim lock-sweep witness
  `docs/jira/v26.10.20/receipts/kd127-lock-sweep-witness.md`; premise-rot
  typed; flip applied.
- **KD-134** — CLOSED-SIMULATED: requester-preference redelivery fix
  (commits 25d5dd0 fix + 4b12321 flip), witness
  `docs/jira/v26.10.20/receipts/kd134-requester-delivery-witness.md`;
  falsifier green.
- **KD-114** — CLOSED-SIMULATED: real @azure/storage-blob 6/6 PASS over the
  9444 TLS twin incl. SharedKey admit + typed 401 tamper refusal
  (`docs/jira/v26.10.20/receipts/kd114-sharedkey-close-witness.md`).
- **KD-129** — CLOSED-SIMULATED: post-shim heartbeat-frame decode witness
  `docs/jira/v26.10.20/receipts/kd129-post-shim-witness.md`.
- **KD-128** — CLOSED-SIMULATED: partition-key fix witness
  `docs/jira/v26.10.20/receipts/kd128-partition-key-fix-witness.md`.
- **KD-130** — CLOSED-SIMULATED: 409 ContainerAlreadyExists live re-probe
  witness `docs/jira/v26.10.20/receipts/kd130-container-exists-witness.md`.
- **KD-35** — CLOSED-WITH-RECEIPT (registrar 2026-10-20): the TLS twin
  serves egress; witness
  `docs/jira/v26.10.20/receipts/kd35-114-tls-plane-witness.md`.
- **KD-116** — CLOSED-WITH-RECEIPT (registrar 2026-10-21): row premise was
  v6-API rot, not a wire gap; diagnosis
  `docs/jira/v26.10.20/receipts/kd115-116-diagnosis.md` §4.

### 3b. Remaining OPEN rows (15), one-line typed reasons

**Minted this window (X3 substrate defects, evidence
`docs/jira/v26.10.20/receipts/x3-sb-topic-publish-subscribe.md`, standing
ALIVE):**

- KD-131 — shared-substrate SAS key under the 32-byte floor: boot path
  pins a 12-byte key, `shared_key/0` falls back to a random per-boot dev
  key → every CBS put-token on the shared plane answers 401.
- KD-132 — AMQP map32 decode truncated at both size semantics + a
  malformed map body crashes the broker connection (server-side
  robustness); client legs carry a map8 workaround.
- KD-133 — broker flow field order is non-standard; spec-ordered flows
  grant zero credit (receiver starvation witnessed live).

**Blob-plane census re-run (W30-D + W32 live audit, 2026-10-21):**

- KD-135 (WORM-by-default) — **OPEN, posture undetermined**:
  pinion-vs-parity not landed; official-SDK delete still 409
  `ContainerLocked` (`receipts/w30-dual-mode-witness.md`, PARTIAL_ALIVE;
  re-verified live `receipts/w32-api-conformance.md` row 9).
- KD-136..141 (per-face error-body rows, census
  `popcorn_demo/azurite-spike/error-census.jsonl`) and KD-142 (systemic
  envelope: smalt renders JSON `{"error":{…}}`, omits `x-ms-error-code`;
  azurite renders StorageError XML + header) — all OPEN; the W32 live
  audit confirms row 8 envelope DIVERGE on the wire today. The
  Azure-XML error contract has NOT landed; flips are receipt-gated via
  `scripts/kd_flip.py`.

**Client-bound:**

- KD-88 — EH checkpoint-store pump warm-up race; server-side root
  REFUTED, remaining scope client-side (see §3a).

**Pre-window opens (minted before v26.10.20; unchanged this window):**

- KD-04 — fix landed 2026-10-17, receipt on disk; flip pending next
  kd_flip pass.
- KD-10 — probe PASS unverified at the code layer (no `PUT /keys/:name`
  route exists); flip blocked pending a real PUT route + kid-naming
  witness.
- KD-13 / KD-75 — soft-delete routes landed 2026-10-17
  (`egress_router.ex:723-752`), witness on disk; flip pending.
- KD-14 — RS256 inversion witnessed (substrate signature refused by Node
  `crypto.verify`); flip blocked on interop re-witness or a contract pin.
- KD-23 — mixed-form `where…|project` KQL falls through to 400 BadQuery;
  status cell now parses (pipe fix, commit 4c26019); no fix site, no
  token; flip blocked.
- KD-79 — loopback-by-design (emulator design constant; may resolve as a
  documented constant).
- KD-86 — emulator-by-design (AMQP send to a never-created queue
  auto-creates; may resolve as a documented constant).
- KD-90 — perf divergence, bench-pinned (affidavit seal latency, b3sum
  subprocess dominance).
- KD-92 — WORM ARM-bridge (I16/L2) not yet landed.
- KD-93 — c11 typed finding (lane X5 registrar) + R7 duplicate-dispatch
  disclosure, unresolved.

## 4. PRD phase coverage (Phases 1–4) — all LANDED + WITNESSED

| phase | subject | witness receipt | standing |
|---|---|---|---|
| Phase 1 | SCVD concurrency harness (`ramp/1`+`contention/1`, S6-audited) | `popcorn_demo/receipts/v261020-s1-concurrency-ramp.md` | ALIVE |
| Phase 2 | Reconciliation engine (real-ETS staging, sha256 consistency hash, monotonic merge; live substrate leg) | `popcorn_demo/receipts/20261021T031500Z-s8-reconcile.md` + `popcorn_demo/receipts/20261021T045021Z-s10-reconcile.md` | ALIVE |
| Phase 3 | In-browser sync stack (BFF `/api/sync/state` etag CAS + LocalSTS + signed delta wire) | `docs/jira/v26.10.20/receipts/w-y2-bff-sync-state-route.md` + `docs/jira/v26.10.20/receipts/scvd-browser-ramp-witness.md` | ALIVE / PASS |
| Phase 4 | Sync-fault verification over the real BFF boundary (8-way concurrent conflict arbitration, offline staging, repeat-run typed conflicts) | `popcorn_demo/receipts/y4-sync-fault-witness.md` (commit c037acb) | PASS (9/9 legs, 0 FAIL, two consecutive green runs) |

## 5. Composed terminal witness — in-browser, 31 legs

Terminal composed receipt:
`popcorn_demo/receipts/20261021T075835Z-witness-all.md` (standing ALIVE,
Context: full, fail ledger: none — all steps green). The in-browser smoke
leg composes all X/Y-wave surfaces into one run: **31 legs — 16 OK / 15
typed SKIP / 0 FAIL** (re-counted from the embedded `SMOKE_RECEIPT` line
this session). The 15 skips are every one typed: 11 `wasm-transport` (the
wasm BEAM lacks `:httpc`, `:public_key`, `:crypto` modules),
`kd101-airgap:local-delivery-unimplemented` (egd), `eh-plane-down`
(5673 `:eprotonosupport`), `cors-preflight-403` (blob create-container),
`ca-missing` (tls). Zero FAIL cells, zero silent skips.

Committed at f81068c ("terminal witness_all ALIVE — all X/Y legs in
composed receipt, 6 steps green").

## 6. Landed-artifact inventory — X-wave and Y-wave legs

Commit 2958d20 (2026-10-20) landed the X-wave legs and Y-wave sync stack;
every path below was `ls`-verified on disk this session.

### 6a. X-wave legs (`popcorn_demo/lib/popcorn_demo/`, each with a matching test in `popcorn_demo/test/`)

- `live_topic.ex` — SB topics/fan-out (ARM + wire)
- `live_egd.ex` — Event Grid delivery
- `live_appconfig.ex` — App Configuration KV + feature flags
- `live_dns.ex` — DNS zones + vNet links (A-record face typed UNSUPPORTED)
- `live_export.ex` — ARM exportTemplate
- `live_apim.ex` / `live_acr.ex` — APIM + Container Registry, typed
  UNSUPPORTED, tripwired
- X1 Next.js embed: iframe boot, 13 legs OK (X-Frame-Options +
  COOP/COEP fixes, e2e-court leg), `workspace/app/popcorn/`

### 6b. Y-wave (browser sync stack)

- `workspace/app/api/sync/state/route.ts` (+ `route.test.ts`) — BFF
  `/api/sync/state`, etag CAS, typed conflicts, live-witnessed
  (`docs/jira/v26.10.20/receipts/w-y2-bff-sync-state-route.md`)
- `popcorn_demo/lib/popcorn_demo/local_sts.ex` — LocalSTS (synthetic
  in-browser tokens)
- `workspace/lib/delta.ts` (signed delta wire format) +
  `workspace/app/popcorn/DeltaSync.tsx` island

## 7. Threshold Wall + tail-invariance — final numbers

### 7a. Host wall

Super-linear scaling wall **LOCATED at N=512** (first rung where every
subsequent doubling exceeds the 2.00x linear expectation: 256→512 = 2.31x,
512→1024 = 2.60x, 1024→2048 = 2.12x, 2048→4096 = 3.84x; per-actor memory
constant through 2048, ~0.7–0.9 KB/actor, then a ~5.2 MB processes jump at
4096). Source: `popcorn_demo/BENCH_SCVD.md` (S2 rungs ≤256 + S14-A2 rungs
512–4096), rows in `popcorn_demo/bench/scvd.jsonl`. The hard boundary
(timeout or VM refusal) is OPEN at N>4096 — untested, not refuted.

### 7b. Tail invariance, 9 runs per rung (W15-C, PRD §2.3)

Per `popcorn_demo/BENCH_SCVD.md` §"Tail invariance, 9 runs per rung
(W15-C, PRD §2.3)": 63 real runs (7 rungs × 9), zero failures, zero errors,
verified=N / breaches=0 at every run; rows in `popcorn_demo/bench/scvd.jsonl`
(`wave: "w15c-tail9"`). **PRD §2.3 tail-invariance HOLDS at 7/7 re-measured
rungs** — the per-actor p99/p50 tail stays ≤1.15 everywhere (max 1.13 at
2048); W15-B's 7/13 actor FAILs were 3-sample noise, typed
PASS-noise-resolution (SCVD tail-invariance resolved, HOLDS 7/7 at 9-run
resolution — commit 3775f4b). The across-run whole-VM wall is a real tail
at 16/128/256/512/1024 (ratios 1.22–1.70; 2048 borderline 1.18 at the 1.15
fence) — cold-boot jitter across fresh VMs, not the §2.3 per-actor metric.
Final rung medians (actor p50/p99 µs, actor ratio):

| N | actor p50 µs | actor p99 µs | actor ratio | verdict |
|---:|---:|---:|---|---|
| 16 | 3,360 | 3,388 | 1.01 | PASS |
| 128 | 3,872 | 3,980 | 1.03 | PASS |
| 256 | 4,320 | 4,504 | 1.04 | PASS |
| 512 | 6,759 | 7,177 | 1.06 | PASS |
| 1024 | 8,941 | 9,961 | 1.11 | PASS |
| 2048 | 15,450 | 17,427 | 1.13 | PASS |
| 4096 | 32,722 | 36,168 | 1.11 | PASS |

## 8. In-browser wall hunt (S18-A) — terminal

Witness: `docs/jira/v26.10.20/receipts/scvd-inbrowser-wall-witness.md`
(standing PARTIAL_ALIVE). `deep/0` added to
`popcorn_demo/lib/popcorn_demo/live_scvd.ex` (`run/0` unchanged), cooked
scratch bundle, headless Chromium, COOP/COEP, 3/3 OK runs, no TIMEOUT
markers fired:

```
DEEP_RUN_1: scvd-deep=OK(512:120.815ms;1024:238.579ms)
DEEP_RUN_2: scvd-deep=OK(512:124.200ms;1024:242.000ms)
DEEP_RUN_3: scvd-deep=OK(512:123.534ms;1024:240.389ms)
DEEP_SUMMARY: 3/3 OK runs
```

Reading (typed): in-browser scaling is **LINEAR through 1024** (clean 2x
per doubling: ~121–124 ms @512, ~239–242 ms @1024; host twin ~7–17 ms @512,
~9–12 ms @1024). The "wasm wall nearer 256–512" prior is REFUTED —
slowness is a constant factor (~8–20x absolute), not a scaling cliff. The
**wall is >1024 in-browser** (rungs beyond 1024 untested at this shape)
while the host wall sits at N=512 — the wasm subject does not inherit the
host wall at these rungs. No GAP token minted; the S18-A flip is
receipt-gated, and this witness IS the receipt.

## 9. Reconciliation engine

- Core: `popcorn_demo/lib/popcorn_demo/reconcile.ex`
  (`stage/2` real-ETS staging + sha256 `consistency_hash/0`; monotonic
  merge: higher-`_v` wins, equal-_v converges, equal-_v divergent bytes →
  typed `:equal_version_divergent_bytes` with nothing overwritten; WORM
  lower-_v refused `:worm_monotonicity`). Receipt:
  `popcorn_demo/receipts/20261021T031500Z-s8-reconcile.md` (10/10 Chicago
  tests pass, real ETS + real `:crypto` sha256, zero mocks, zero sleeps;
  standing ALIVE in-receipt; indexed NO-CONTEXT by the testbed index
  parser — a header-format parse artifact, not an output-less receipt; the
  embedded output is real).
- Live leg: `popcorn_demo/lib/popcorn_demo/live_reconcile.ex`
  (`LiveReconcile.run/0` over the real substrate wire: STS mint → real etag
  CAS seeding → real feed fetch → monotonic winners pushed by real
  `If-Match` CAS → typed conflict preserves remote bytes). Receipt:
  `popcorn_demo/receipts/20261021T045021Z-s10-reconcile.md` (real run
  output
  `reconcile=OK(3-staged,seeded,feed-6,monotonic,typed-conflict,cas-winners)`,
  3/3 Chicago tests pass twice consecutively; standing ALIVE, NO-CONTEXT
  index flag only).

## 10. Zero-egress

`popcorn_demo/scripts/egress_gate.sh` (fail-closed; exit 0 PASS / 1
EGRESS_GATE_REFUSED / 2 usage / 3 RAMP_ABSENT loud). Both flip directions
witnessed in the session recorded by
`docs/jira/v26.10.20/scvd-audit-report.md` appendix A5–A8: full gate
(static scan over `popcorn_demo/lib` + `public`, plus runtime ramp(64)
verified=64 breaches=0 with 0 non-loopback sockets) exit 0 PASS; foreign
URL literal refused exit 1 `EGRESS_GATE_REFUSED[URI_DNS]`; non-loopback
IP literal refused exit 1 `EGRESS_GATE_REFUSED[IP_LITERAL]`. A gate that
cannot flip is vacuous; both refusal classes are witnessed.

## 11. Memory (S9)

`popcorn_demo/BENCH_SCVD.md` §"In-browser memory (S9 lane)": main-thread
JS heap 10,000,000/10,000,000 B (~9.5 MiB) vs the 32 MB budget — PASS,
quantized-class. The BEAM wasm worker heap and `WebAssembly.Memory`
committed size are **UNMEASURABLE-(exposed-surface)** (no exposed API
reaches them; typed in `BENCH_SCVD.md`); the CDP witness
`docs/jira/v26.10.20/receipts/wasm-memory-cdp-witness.md` measured the
worker reservation at ~64 MiB against the 32 MB ceiling — verdict
REFUTED on the allocated-reservation measure (2.0x budget), with the
committed-heap breakdown per target still unmeasured (CDP Performance
unsupported on worker targets in this headless shell). The typed close
condition lives in `BENCH_SCVD.md` (a Popcorn/harness exposing the
`WebAssembly.Memory` buffer size or CDP `Performance.getMetrics` on the
worker target flips this verdict).

## 12. Economic standing law

Per `docs/jira/v26.10.20/scvd-ledger.md` §3: every PRD dollar/economic
claim is **UNSUPPORTED** until a measured counterpart exists on disk; a
claim flips only by citing a receipt whose embedded output contains the
measured number. This wrap asserts no dollar figure; no prose valuation
(cost model, ROI, $/run) exists on disk at wrap time.

## 13. Open boundaries (typed, receipt-gated)

1. **Worker-heap unmeasured**: committed-heap breakdown per target —
   UNMEASURABLE-(exposed-surface) at the current exposed surface; close
   condition typed in `popcorn_demo/BENCH_SCVD.md` (S9); reservation face
   REFUTED (64 MiB vs 32 MB ceiling, CDP witness).
2. **Wall beyond 4096 (host) / beyond 1024 (in-browser)**: the hard
   boundary (timeout or VM refusal) is OPEN beyond the deepest measured
   rung — untested, not refuted (`BENCH_SCVD.md` S14-A2;
   `scvd-inbrowser-wall-witness.md`).
3. **Dollar displacement**: every economic claim UNSUPPORTED
   (`scvd-ledger.md` §3 law); flips only by measured receipt.
4. **KD-88 + KD-131/132/133**: the register's remaining this-window-family
   OPEN rows (client-bound capture lane; X3 substrate defects) — §3a/§3b.
5. **Blob error-face + WORM (KD-135..142)**: the Azure-XML error contract
   (StorageError XML + `x-ms-error-code` header) and the KD-135
   pinion-or-parity determination are OPEN, receipt-gated — §3b; live
   verdicts `receipts/w32-api-conformance.md` (PARTIAL_ALIVE).

## 14. Wrap verification commands (this session)

```
$ wc -l popcorn_demo/bench/scvd.jsonl
     109
$ python3 popcorn_demo/scripts/receipt_index.py
receipts=33 SUSPECT=0 NO-CONTEXT=23
wrote /Users/sac/smalt/popcorn_demo/receipts/INDEX.md
(rc=0)
$ just docs-dod-check
(recorded below, run post-write)
```

## 15. Integration cautions — Azure emulator deep-research (W30-M)

Source: `docs/jira/v26.10.20/receipts/azure-emulators-deep-research.md`
(`ls`-verified on disk this session; standing: deep-research receipt, 100-agent
cited run, adversarial verification 25 claims → 23 confirmed / 2 refuted /
0 unverified). Integration cautions carried into the SCVD wrap:

1. **Azurite port plan** — Azurite's default endpoints are Blob 10000 /
   Queue 10001 / Table 10002 on 127.0.0.1 (configurable via
   `--blobPort/--queuePort/--tablePort`). Any shared test environment
   running Azurite alongside smalt must be checked for collisions against
   smalt's port plan (control 9443, TLS twin 9444, data plane 8443, AMQP
   5672/5673, MCP 9543-adjacent 9545). The receipt confirms the collision
   risk is the default, not a corner case.
2. **Service Bus emulator management is .NET-native, HTTP 5300 is not a
   native surface** — the official SB emulator runs as a Linux Docker
   container paired with SQL Server 2022 (AMQP 5672); management
   operations ride HTTP 5300 (`EMULATOR_HTTP_PORT`, connection string
   must append `:5300` for the Administration Client), which is natively
   .NET-only. Raw HTTP against 5300 is a non-native management face —
   smalt interop courts must not treat it as a wire-parity surface.
3. **Cosmos vNext enforces no auth → smalt `:enforce` is the
   auth-testing surface** — the vNext Linux Cosmos DB emulator exposes
   health probes (`/alive`, `/ready`, `/status`) but does not enforce
   authentication (Azurite similarly validates only issuer/audience/expiry
   under `--oauth basic`, never signature or permissions, and V3 provides
   no auth-bypass option). smalt's `:enforce` STS/bearer mode therefore
   tests real auth behavior the official emulators cannot — it is the
   auth-testing surface of the local-emulation stack, not a parity liability.
4. **SDK-guideline sanction** — the Azure SDK engineering guidelines
   directly sanction smalt's testing shape: offline tests with no
   live-Azure access (general-testing-6), version-pinned recorded tests
   against explicit api-versions (general-testing-8, matching smalt's
   KD-78 monotonic admission), and dual-mode mocked/live tests with
   unchanged assertions (general-testing-9) — i.e., a
   smalt-vs-real-Azure differential test with a swapped endpoint is the
   guideline-native verification pattern.
5. **Error-body divergence census = KD-register material** — Azurite
   documents that status codes align but error message bodies can differ
   from real Azure Storage (no 100% alignment, Table still preview). This
   is the same divergence class the KD register tracks; a differential
   Azurite-vs-smalt-vs-Azure error-body census is candidate KD-register
   rows (per repo law: minted via the registrar lane, never unilaterally).

## See Also

- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — canonical KD register (ground truth)
- `docs/jira/v26.10.20/KNOWN_DIVERGENCES.md` — window pointer register (KD-122..KD-134)
- `docs/jira/v26.10.20/scvd-audit-report.md` — S15 immutable audit (tier table, wall, egress flips)
- `docs/jira/v26.10.20/scvd-ledger.md` — PRD-to-reality ledger + economic standing law
- `popcorn_demo/BENCH_SCVD.md` — host bench + S9 memory + W15-C tail-invariance
- `docs/jira/v26.10.20/receipts/scvd-inbrowser-wall-witness.md` — S18-A in-browser wall hunt
- `docs/jira/v26.10.20/receipts/scvd-browser-ramp-witness.md` — in-browser tier legs
- `popcorn_demo/receipts/v261020-s1-concurrency-ramp.md` — S1/S6 harness receipt
- `popcorn_demo/receipts/20261021T031500Z-s8-reconcile.md` +
  `popcorn_demo/receipts/20261021T045021Z-s10-reconcile.md` — reconciliation
- `popcorn_demo/receipts/y4-sync-fault-witness.md` — PRD Phase-4 fault verification
- `popcorn_demo/receipts/20261021T075835Z-witness-all.md` — terminal composed witness (31 legs)
- `docs/jira/v26.10.20/_LANES.md` — lane partition
