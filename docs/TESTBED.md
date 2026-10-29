# TESTBED — popcorn_demo as the Chicago-school testbed

Charter for `popcorn_demo/` as smalt's in-repo Chicago testbed: real
collaborators, real state, no mocks; skips are loud, gates are non-vacuous.

## Purpose

`popcorn_demo/` is the standing testbed where both runtimes that execute
smalt's pure-decision slice — the host Elixir VM and the in-browser Popcorn
WASM BEAM — exercise the LIVE smalt substrate on loopback, not a fixture.

Legs currently receipted or in flight:

- **9443 control plane (ALIVE, receipted)** — exempt probes
  (`GET /metadata/endpoints`, `GET /tenants`), STS mint
  (`POST /{tid}/oauth2/v2.0/token`), and a bearer-auth round trip
  (`GET /subscriptions?api-version=2022-12-01`). Witness:
  `scripts/browser_smoke.mjs` emits `live=OK(...)`.
- **8443 data plane (being added)** — cosmos docs round trip and blob
  put/get round trip against the live data plane, same loopback substrate.

Each leg emits a typed receipt fragment into the smoke receipt line:
`live=…` (control plane), `matrix=…` (cosmos docs), `blob=…` (blob bytes).
A fragment is either `OK(<evidence>)`, `FAIL(<reason>)`, or
`SKIP(<reason>)` — never absent-when-claimed and never a bare boolean.

## Chicago discipline on this testbed

- **Real collaborator** means: the live substrate process (real sockets,
  real stored bytes), real HTTP (`:httpc` host-side, `Popcorn.Fetch`
  in-browser), and assertions on real state read back from the substrate
  (the bytes you PUT are the bytes you GET), never on call counts or a
  test's own model of the server. Per `[[testing-chicago-style]]`,
  mocking is banned by default.
- **The ONE named double exception**: `Popcorn.Fetch` is browser-only —
  there is no in-process host substitute because the browser JS bridge does
  not exist outside Chromium. The host side therefore uses real `:httpc`
  as a degraded REAL alternative, never a mock. Any future double on this
  testbed needs its own named exception entry here first.
- **No-sleep law** (`docs/NO_SLEEP_DOCTRINE.md`): no fixed
  `Process.sleep` coordination. Bounded polls on real observables only
  (`SmaltTest.AssertEventually` host-side; deadline-checked poll loops in
  the smoke harness). A substrate-not-up condition is observed via
  connect failure, not waited out.
- **Exit-code contract** for `node scripts/browser_smoke.mjs` (keyed on the
  `live=` fragment, the loopback auth-path leg — refresh 2026-10-22,
  BK-TESTBED): `live=OK` → `0` (any other leg's `=FAIL` still forces `1`,
  fail-closed); `live=SKIP` → `3` loud, `0` with `SMOKE_ALLOW_OFFLINE=1`
  (the exit-3 verdict is preserved even if the SCVD fragment gate would
  pass — `finalExit` never upgrades a 3); `live=FAIL` or missing receipt →
  `1`. When `live` itself skipped, other legs' `=FAIL` fragments are
  substrate-down artifacts — they ride visibly in the printed receipt but
  do not force `1`. A skip must print its reason; a gate that cannot exit 1
  is vacuous.

## Charter table

| Leg | Module / harness | Receipt fragment | Gate |
|---|---|---|---|
| Control plane (9443): exempt probes + STS + bearer round trip | `scripts/browser_smoke.mjs` (browser, `Popcorn.Fetch`) | `live=OK(endpoints,tenants,sts,subscriptions=N)` | exit contract keyed on the `live=` fragment: 0 / 1 / 3 (see Exit-code contract above) |
| Control plane, host degraded-real leg | `popcorn_demo/test/` host smoke (`:httpc`) | `live=SKIP(no-bridge)` when no JS bridge | `mix test` (popcorn_demo) |
| Cosmos docs round trip (8443) | `popcorn_demo/lib/popcorn_demo/live_matrix.ex` | `matrix=…` | this charter; gate lands with its receipt |
| Blob put/get round trip (8443) | `popcorn_demo/lib/popcorn_demo/live_blob.ex` | `blob=…` | this charter; gate lands with its receipt |
| TLS twin walk (9444) | `popcorn_demo/lib/popcorn_demo/live_tls.ex` | `tls=…` | this charter; gate lands with its receipt |
| ARM resource graph / templated ARM walk | `popcorn_demo/lib/popcorn_demo/live_rules.ex` | `rules=…` | this charter; gate lands with its receipt |
| Queue put/get round trip | `popcorn_demo/lib/popcorn_demo/live_queue.ex` | `queue=…` | this charter; gate lands with its receipt |
| Key Vault secret round trip | `popcorn_demo/lib/popcorn_demo/live_kv.ex` | `kv=…` | this charter; gate lands with its receipt |
| Blob containers walk | `popcorn_demo/lib/popcorn_demo/live_containers.ex` | `containers=…` | this charter; gate lands with its receipt |
| ARM parameters (template parameter objects) | `popcorn_demo/lib/popcorn_demo/live_param.ex` | `param=…` | this charter; gate lands with its receipt |
| MCP tool surface (9545) | `popcorn_demo/lib/popcorn_demo/live_mcp.ex` | `mcp=…` | this charter; gate lands with its receipt |
| Certificate operations | `popcorn_demo/lib/popcorn_demo/live_certs.ex` | `certs=…` | this charter; gate lands with its receipt |
| ARM resource graph | `popcorn_demo/lib/popcorn_demo/live_rg.ex` | `rg=…` | this charter; gate lands with its receipt |
| Event Grid delivery | `popcorn_demo/lib/popcorn_demo/live_eg.ex` | `eg=…` | this charter; gate lands with its receipt |
| ARM policy initiatives | `popcorn_demo/lib/popcorn_demo/live_policy.ex` | `policy=…` | this charter; gate lands with its receipt |
| Optimistic concurrency (ETag CAS) | `popcorn_demo/lib/popcorn_demo/live_cas.ex` | `cas=…` | this charter; gate lands with its receipt |
| Key Vault key operations | `popcorn_demo/lib/popcorn_demo/live_keyops.ex` | `keyops=…` | this charter; gate lands with its receipt |
| Resource tags round trip | `popcorn_demo/lib/popcorn_demo/live_tags.ex` | `tags=…` | this charter; gate lands with its receipt |
| Container-app lifecycle (create → start → stop → delete) | `popcorn_demo/lib/popcorn_demo/live_lifecycle.ex` | `lifecycle=…` | this charter; gate lands with its receipt |
| Local↔cloud reconcile walk | `popcorn_demo/lib/popcorn_demo/live_reconcile.ex` | `reconcile=…` | this charter; gate lands with its receipt |
| In-browser SCVD tier legs | `popcorn_demo/lib/popcorn_demo/live_scvd.ex` | `scvd=…` | this charter; see SCVD section below |
| Event Hubs publish | `popcorn_demo/lib/popcorn_demo/live_eh.ex` | `eh=…` | this charter; gate lands with its receipt |
| Service Bus topic pub/sub loop | `popcorn_demo/lib/popcorn_demo/live_topic.ex` | `topic=…` | this charter; gate lands with its receipt |
| Event Grid local delivery (webhook plug) | `popcorn_demo/lib/popcorn_demo/live_egd.ex` | `egd=…` | this charter; gate lands with its receipt |
| API Management surface | `popcorn_demo/lib/popcorn_demo/live_apim.ex` | `apim=…` | this charter; gate lands with its receipt |
| App Configuration KV round trip | `popcorn_demo/lib/popcorn_demo/live_appconfig.ex` | `appconfig=…` | this charter; gate lands with its receipt |
| DNS zone walk | `popcorn_demo/lib/popcorn_demo/live_dns.ex` | `dns=…` | this charter; gate lands with its receipt |
| ARM template export | `popcorn_demo/lib/popcorn_demo/live_export.ex` | `export=…` | this charter; gate lands with its receipt |
| Container Registry (typed UNSUPPORTED: no ACR face) | `popcorn_demo/lib/popcorn_demo/live_acr.ex` | typed `{:unsupported, :acr_face_absent}` skip | loud-skip contract; re-author when a `/v2/` face lands |

Landing next: none currently named as modules-not-on-disk; every row above is
verified on disk (`ls popcorn_demo/lib/popcorn_demo/`, 2026-10-20).

Wave-2/3 legs (tls=, rules=, queue=, kv=, containers=, param=, mcp=, certs=,
rg=, eg=) landed concurrently with this charter update; each is named above
only after its module was verified on disk (`ls popcorn_demo/lib/popcorn_demo/`,
2026-10-20).

### Toolchain law (host-side live walks)

Host-side live walks (`:httpc`, `:gen_tcp`, smoke harness) run under
**Elixir 1.20.3-otp-28 / Erlang 28.3.1**. OTP **29.0.6** is broken for this
surface: its `inets` lacks `http_util:timestamp/0`, so every `:httpc` call
crashes (witnessed on lane R9, 2026-10-20). `mix popcorn.cook` remains pinned
to the packager's exact-match **29.0.6** toolchain — cook and host-walk use
**different** toolchains by law; do not unify them toward either side.

### Port plan vs official emulators (W30-E audit, 2026-10-21)

Full audit: `docs/jira/v26.10.20/receipts/w30-port-audit.md`. Summary of the
static on-disk audit (standing ALIVE):

- smalt listeners: ARM 9443, TLS twin 9444, data 8443, AMQP SB 5672, EH 5673,
  MCP 9545, workspace BFF 3100, lane blocks 39xxx (b/c/e laws per
  `scripts/bench/REGISTRY.md`).
- Official emulator defaults: Azurite 10000/10001/10002; Service Bus emulator
  AMQP 5672 + mgmt 5300; Cosmos classic 8081 / vNext 8080; Event Hubs emulator
  AMQP (compose-default 5672-class).
- **Collision: 5672** — smalt's AMQP Service Bus plane vs the Service Bus
  emulator (and EH emulator compose default). Co-residency on defaults is a
  real outage, not theoretical (deep-research cites a RabbitMQ-occupied-5672
  incident in the EH emulator repo).
- Near-misses, no overlap: SB emulator 5300, Cosmos 8080/8081, Azurite
  10000-10002 vs smalt's 9443/9444/8443/9545/5673/3100/39xxx — all disjoint.
  The lane band answers the deep-research open question: no collision between
  Azurite 10000-10002 and any 39xxx allocation.

**Isolation rule**: any co-resident official emulator must be pinned off
smalt's plan — shifted ports (Azurite `--blobPort/--queuePort/--tablePort`;
SB emulator compose map + `EMULATOR_HTTP_PORT`; Cosmos `--port`/compose map)
or a private lane block, per the b13/b90 precedent
(`scripts/substrate-ctl up --block <name>`, receipts kd73-74 / KD-131 x3).
Never run emulator defaults alongside the shared canonical substrate. The
rule is prose until a fail-closed port gate lands (successor work); the
existing mechanism is `bench_boot`'s lsof pre-flight, which covers lane
scopes only.

## Official emulator interop

Microsoft's first-party local-emulation stack maps onto smalt's surface, and
the Azure SDK engineering guidelines sanction smalt's test shape. Canonical
finding: `docs/jira/v26.10.20/receipts/azure-emulators-deep-research.md`
(100-agent cited deep-research run; 18 first-party sources fetched
2026-10-21, 25 claims adversarially verified → 23 confirmed / 2 refuted /
0 unverified). Headline: Azurite (Blob/Queue/Table, defaults 10000/10001/10002,
supersedes the retired Storage Emulator), the Service Bus emulator (Docker +
SQL Server, AMQP 5672, mgmt HTTP 5300 — natively .NET-only), the Event Hubs
Emulator (AMQP + Kafka), and the Cosmos DB emulator (classic 8081 / vNext
Linux 8080 with `/alive`, `/ready`, `/status` health probes). Every official
emulator documents the same divergence class smalt's KD register tracks:
aligned status codes but differing error bodies, partial feature surfaces,
hard quotas, and weak-or-absent auth enforcement. Guideline sanction:
offline-only tests (general-testing-6), version-pinned recorded tests
targeting explicit api-versions (matching smalt's KD-78 monotonic admission),
and dual-mode mocked/live tests with unchanged assertions (testing-9) —
a smalt-vs-emulator-vs-real-Azure differential with a swapped endpoint is the
guideline-native verification pattern. Integration cautions are carried in
`docs/jira/v26.10.20/scvd-wrap.md` §15 (W30-M).

Interop artifacts, named only after on-disk verification (2026-10-21):

| Lane | Artifact (verified on disk) | Status |
|---|---|---|
| W30-A | `popcorn_demo/azurite-spike/` — Azurite spike: `probe.mjs`, `scvd-azurite.mjs`, results `scvd-azurite.jsonl`, Azurite data dirs | landed (spike) |
| W30-D | `popcorn_demo/azurite-spike/error-census.mjs` — differential error-shape census, smalt 9444 TLS twin (SharedKey) vs Azurite | landed (harness) |
| W30-E | `docs/jira/v26.10.20/receipts/w30-port-audit.md` — static port-collision audit (see "Port plan vs official emulators" above) | ALIVE |
| W30-G | `popcorn_demo/azurite-spike/dual-mode-test.mjs` — testing-9 dual-mode witness: one suite, unchanged assertions, two backends | landed (harness) |
| W30-I | `docs/jira/v26.10.20/receipts/w30-health-probe-pattern.md` — Cosmos DB vNext Linux emulator health-probe pattern witness (real container `vnext-preview` booted, `/ready` polled to 200 under a bounded no-sleep deadline, `/alive` `/ready` `/status` = 200; REPORT-ONLY, container removed) | ALIVE (pattern witnessed) |
| W30-N | `scripts/emulators.sh` — fail-closed emulator manager (Azurite 10100-10102, SB emulator 5300-class with collision shift-up, Cosmos vNext 8080; Docker-absent → typed `EMULATORS-DOCKER-ABSENT` exit 3, refuses any held port, state `/tmp/smalt-emulators-state/`) | landed |
| W30-S | `popcorn_demo/azurite-spike/scvd-azurite.jsonl` — `w30-s` lane result rows | **FAIL** (honest): smalt's api-version pin `2026-10-06` exceeds the Azurite build's supported API version; 0 pass / 5 fail × 2 runs, typed `InvalidHeaderValue`-class error bodies captured — this is exactly the error-census divergence class, next step is an Azurite upgrade or `--skipApiVersionCheck` in the spike lane |
| W30-H | `docs/jira/v26.10.20/receipts/sb-mgmt-5300-probe.md` — official SB emulator (5300→15300) vs smalt ARM SB face interop probe | PARTIAL_ALIVE |
| W30-J2 | `docs/jira/v26.10.20/receipts/w30-auth-court.md` — auth-enforcement divergence court, three backends (smalt/Azurite/Cosmos vNext), 11-row auth-court.jsonl | PASS |

Remaining interop lanes (recorded-test pattern) have no artifacts on disk
yet; per the ls-verify law they are not named here until they land, and
then only with their verified paths.

### Blob error-face + WORM posture (as of 2026-10-21)

NOT yet the Azure-XML contract: the blob plane still renders storage
errors as JSON `{"error":{...}}` and omits the `x-ms-error-code` response
header — registered systemically as KD-142 (with per-face rows KD-136..141:
InvalidRange past-EOF, unknown `?comp=`, headerless blob PUT, missing
Content-Length, invalid `x-ms-meta-*`), evidence
`popcorn_demo/azurite-spike/error-census.jsonl` (census W30-D, 2026-10-21).
Live spec-cited conformance: `docs/jira/v26.10.20/receipts/w32-api-conformance.md`
(standing PARTIAL_ALIVE; blob leg row 8 = envelope DIVERGE, row 9 = KD-135
observed live). WORM-by-default posture: **KD-135 remains OPEN** — the
pinion-vs-parity determination has not landed; container delete/overwrite
still answers 409 `ContainerLocked` via the official SDK
(`docs/jira/v26.10.20/receipts/w30-dual-mode-witness.md`, standing
PARTIAL_ALIVE). Any flip runs receipt-gated via `scripts/kd_flip.py`.

## SCVD (Sovereign Concurrency & Value Discovery)

Chartered measurement lane over `PopcornDemo.Concurrency`
(`popcorn_demo/lib/popcorn_demo/concurrency.ex`, S6-audited: actor crashes
are monitor-classified as typed `:invariance_breach` — fail-closed, never a
silent parent hang — and the verification walk is byte-exact or breach:
anything not byte-exact is a breach, the walk never coerces).

- Script: `popcorn_demo/scripts/bench_scvd.sh`; results:
  `popcorn_demo/bench/scvd.jsonl` (verified on disk: 46 rows — 39 ramp +
  6 contention + 1 baseline; zero error rows, zero
  `invariance_breach` outcomes).
- **MEASURED tier verdicts** (`popcorn_demo/BENCH_SCVD.md`; PRD targets
  Tier1 <500ms/<16MB, Tier2 <750ms/<24MB, Tier3 <1200ms/<32MB):
  Tier 1 PASS (83x / 13x margin), Tier 2 PASS (124x / 20x), Tier 3 PASS
  (199x / 26x) — 6.02 ms ramp wall / +1.2 MB ramp-attributable memory
  increment at N=256, median-of-3 cold runs. Subject typed: HOST BEAM
  (OTP 28, JIT). In-browser (wasm BEAM) Tier-2/3 latency: WITNESSED —
  `ramp(256)` 64.0–65.2 ms across 3 headless-Chromium runs (~18x margin
  vs the 1200 ms Tier-3 bound), `contention(128)` deterministic
  (`w8/l120/committed8` every run), receipt
  `docs/jira/v26.10.20/receipts/scvd-browser-ramp-witness.md`;
  `live_scvd.ex` emits `scvd=OK(...)` / `FAIL(...)` / `SKIP(...)`. The
  wasm worker heap face stays as scoped under S9 below.
- **Threshold Wall: LOCATED at N=512** — the first super-linear doubling
  (256→512 at 2.31x vs the 2.00x linear expectation); super-linear
  through 4096 (512→1024: 2.60x, 1024→2048: 2.12x, 2048→4096: 3.84x) and
  per-actor memory constant breaks past 2048 (~5.2 MB processes jump at
  4096). Below 512 the wall is flat within noise; no rung timed out
  (worst 297.3 ms vs the 120s fence), verified=N, breaches=0 through
  4096. Typed: super-linear scaling wall, not a hard/jail boundary; the
  hard boundary at N>4096 remains open.
- **Memory vs the 32MiB ceiling (S9)**: main-thread JS heap ~9.5 MiB
  measured → **PASS** (3.4x margin, bucket-stable across 4 runs). The
  surface where the ceiling binds hardest — the BEAM wasm worker heap — is
  **UNMEASURABLE-(exposed-surface)**: `performance.memory` is absent in the
  worker context, `measureUserAgentSpecificMemory` SecurityError in the
  headless shell, and no Popcorn global exposes the `WebAssembly.Memory`
  handle. Close condition: a Popcorn/harness change exposing the worker's
  wasm memory size (e.g. `Module.wasmMemory` on the worker global) or
  CDP-level `Performance.getMetrics` on the worker target.
- **Contention is deterministic ≤200 actors**: CAS over 8 keys at
  N ∈ {32, 128} × 3 runs — exactly 8/8 winners and 8/8 committed rows every
  run; the `not_deterministic` outcome never fired.
- **Economic claims (dollar displacement): UNSUPPORTED —** per the
  scvd-ledger law, no dollar figure is asserted, implied, or inherited from
  this lane; any dollar claim requires its own measurement protocol.

## KD status matrix (final, 2026-10-20)

Canonical register: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (table is
ground truth). Window pointer rows: `docs/jira/v26.10.20/KNOWN_DIVERGENCES.md`.

| Row | Status | Evidence |
|---|---|---|
| KD-122 blob CORS preflight | **CLOSED-SIMULATED** (canonical) | `receipts/kd122-blob-cors-close-witness.md`; in-browser `blob=OK` flip |
| KD-123 queue urlencoded PUT | **CLOSED-SIMULATED** (canonical) | `receipts/kd123-queue-ct-close-witness.md` |
| KD-124 ARM ns first-PUT 500 | **CLOSED-SIMULATED** (canonical) | `receipts/kd124-namespace-put-close-witness.md` |
| KD-125 ARM policy list crash | **CLOSED-SIMULATED** (canonical) | `receipts/kd125-policy-list-close-witness.md` |
| KD-126 (next id) | **minting** — W10-A in flight; flips forbidden until minted | v26.10.20 register: "Mint from KD-126" |

K-wave dispositions (counts per canonical register; rows not re-enumerated
here — each links its witness receipt under
`docs/jira/v26.10.20/receipts/`):

- **FIXED + flip-eligible: 13 rows** — kd06 (typed-UNSUPPORTED closure via
  the CosmosSql translator), kd08/09/36/44 (KD-COVERS shims in `lib/`),
  kd28/58/59 (fix landed, wire-witnessed), kd55/56/57 (FLIP-ELIGIBLE),
  kd64/65 (PATCH engine + scripts falsifier green).
- **OBSOLETE: 8 rows** — kd24/25/26/27 (row evidence stale, close condition
  already met on wire) and kd29/30/31/32 (face live, register row stale).
- **PINION: 0 rows** — no wire-parity pinion disposition issued this wave.
- **HEAVY: 3 rows** — kd114/115/116, dispositioned (not fixed) in
  `receipts/k8-tail-rows-dispositions-kd114-115-116.md`; blob twin
  dispatch redesign (114) and the SB receiver attach/credit seam (115,
  116 downstream), each needing a real-SDK diagnosis loop.

Closer law: `popcorn_demo/scripts/close_kd.sh` refuses PINION/OBSOLETE
flips (no KD-COVERS shim -> exit 3) and no-op applies (already-CLOSED ->
loud REFUSED exit 1); all four exit-path branches witnessed in
`receipts/w9b-close-kd-generalized.md`.

## Terminal witness

The one-command terminal witness for the whole testbed is
`popcorn_demo/scripts/witness_all.sh` (verified on disk 2026-10-20). It
cooks the suite, boots the substrate, runs the browser + host legs, and
emits the composed SMOKE_RECEIPT line; per-leg SKIPs stay loud with their
reason (`wasm-transport:<r>` / `eh-plane-down(<port>)` / `ca-missing`).

## Receipts

Witness receipts live in `popcorn_demo/receipts/` (markdown, one per
leg/wave), following the repo convention: a standing line
(`ALIVE` / `PARTIAL_ALIVE` / `PASS` / `SUSPECT` / `FAIL`) plus embedded
real command output (exit codes, receipt lines, test counts).
`receipt_index.py` flags any receipt with no embedded command output as
`SUSPECT` — that flag is the standard, not an insult. JSON scratch output
under `tmp/` is not a receipt.

## Named exceptions and knobs (integration receipts, 2026-10-20)

- **blob browser leg — tracked close condition (was: named exception).**
  The blob plane's CORS is stored-rules-only (w6ay; a stored `<Cors>` rule
  answers preflight) and `/healthz` sat before the CORS plug, so an
  in-browser blob walk 403'd at preflight. B1 root cause: Plug.Parsers
  swallowing single-segment PUT bodies (KD-122 mechanism) — fixed via the
  `raw_blob_put?` clause + w6r_fallthrough halt. B2 (healthz CORS) and S2
  (header-knob gate) are closed. The host leg (`:gen_tcp`, CORS-blind) is
  the real witness — `blob=OK(...:61-roundtrip)` ×4. **KD-122 is now
  CLOSED-SIMULATED** (flip verified in
  `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`; witness receipt
  `docs/jira/v26.10.20/receipts/kd122-blob-cors-close-witness.md`:
  post-restart in-browser `blob=OK(popcorn/.../receipt.txt:61-roundtrip)`,
  SMOKE_RECEIPT EXIT=0, witness postdates the shim). The `blob=SKIP` →
  `blob=OK` flip is witnessed. KD-122's second half also landed: blob
  actual (non-OPTIONS) responses echo `Access-Control-Allow-Origin`
  from the matched rule.

## Closure lanes (status 2026-10-20, wave-2 update)

| Lane | Artifact | Status |
|---|---|---|
| B1 | blob preflight root-cause | **CLOSED** — root cause is Plug.Parsers swallowing single-segment PUT bodies (KD-122 mechanism); fix landed: `raw_blob_put?` clause + w6r_fallthrough halt; post-restart browser witness landed (`blob=OK`, KD-122 CLOSED-SIMULATED) |
| B2 | `/healthz` CORS ordering | **CLOSED** — healthz behind CORS plug; 6 tests green |
| B3 | blob outcome typing | in flight — `blob=FAIL(<typed>)` contract; witness receipt |
| B4 | KD row (blob preflight) | **CLOSED** — KD-122 flipped CLOSED-SIMULATED via `scripts/kd_flip.py`, gated on the witness receipt postdating the shim (`docs/jira/v26.10.20/receipts/kd122-blob-cors-close-witness.md`) |
| B5 | ACAO echo on blob actuals | **CLOSED** — blob actual (non-OPTIONS) responses echo `Access-Control-Allow-Origin` from the matched CORS rule (KD-122's second half; same shim stack as the preflight fix, witnessed in the KD-122 close receipt) |
| M1 | skip-reason labels | in flight — `SKIP(substrate-down:<r>)` / `SKIP(transport:<r>)`; gate exits 3 |
| M2 | test down-skip shape | in flight — host test down-skip matches M1 labels; mix test green |
| S2 | CORS knob gate | **CLOSED** — `arm_cors`/`egress_cors` header-knob gate receipt landed |
| T1 | playwright cache | in flight — healthy cache + system-Chrome fallback order witnessed |
- **Transport consolidation — COMPLETE.** All browser legs ride one
  transport (`Popcorn.Fetch` in-browser, `:httpc` host-side), normalized
  at the seam by `decode_body/1`; per-leg HTTP client code was retired
  with the consolidation. The CORS headers extension landed with it: both
  CORSPlug faces pass `headers: ["*"]` (config `:smalt,
  :arm_cors_headers` / `:egress_cors_headers`), echoing
  `Access-Control-Request-Headers` so in-browser preflights admit
  `x-ms-documentdb-partitionkey` etc. Witnessed: preflight on 8443 cosmos
  POST 204; browser `matrix=OK`.
- **wasm-transport SKIP law.** Inside the Popcorn WASM BEAM, `:httpc` and
  raw TCP do not exist — legs that need them SKIP loudly, never fake a
  pass: `SKIP(wasm-transport:httpc undefined)`,
  `SKIP(wasm-transport:tcp_connect eprotonosupport)`, etc. (witnessed in
  `popcorn_demo/receipts/20261021T013518Z-closure-final.md`). A wasm
  context proves the decision slice, not the socket layer; the host walk
  (`witness_all.sh`) is the socket-layer witness.
- **Browser fetch quirks witnessed in-slice.** GET/HEAD with an empty-string
  body is rejected by the browser (`Request with GET/HEAD method cannot have
  body`) — `PopcornDemo.LiveMatrix.req/3` omits body on GET. JSON bodies from
  `Popcorn.Fetch` are raw binary; `decode_body/1` normalizes both transports
  to one contract.
- **Gate poll discipline.** `browser_smoke.mjs` waits for the composed line
  (`live=`) — the app writes twice (smoke, then smoke+legs); a partial read
  previously exited 0 on a legs-less receipt (witnessed, then fixed).
- **Receipt standing folds HOST_EXIT.** `receipt_testbed.sh` maps
  `HOST_EXIT≠0` → SUSPECT even when fragments printed (audit finding L7-2,
  closed).

## ERRC cadence

Policy for what enters this testbed, ordered: Eliminate > Reduce > Raise >
Create ([[entropic-annealing-doctrine]] §2 asymmetry).

- **Eliminate first.** Dead code, unreferenced gates, and retired legs get
  deleted, not commented or flag-gated — a deleted thing cannot regress.
  The `justfile.d/41-popcorn-errc.just` module, `close_kd122.sh`, and the
  generalized `close_kd.sh` closer are landed and receipted
  (`receipts/w9b-close-kd-generalized.md`). KD flips are closer-script-gated
  (`popcorn_demo/scripts/close_kd.sh` refuses no-op applies —
  `REFUSED(KD-122): register row is already CLOSED-SIMULATED` — witnessed), and
  the receipt index carries a Supersedes law: `receipt_index.py --check`
  excludes retired scratch, so a superseded receipt never holds a register
  cell open.
- **Reduce next.** One transport implementation per wire surface, one
  canonical doc home per law. N implementations of one calculus = O(N²)
  drift — witnessed twice (CORS echo faces; smoke vs host receipt
  contracts). `decode_body/1` is the pattern: normalize at the seam.
- **Raise when adding.** A new enterprise leg lands only with all three:
  a typed receipt fragment (`OK/FAIL/SKIP(<evidence>)`), a Chicago test
  against the live substrate, and a ratio fence or an explicit
  `UNSUPPORTED(<reason>)` receipt. Two of three is not landed.
- **Create last**, only when E/R/R are drained for the order. Every new
  gate is non-vacuous via shim court (BASELINE → BEFORE → SHIM → AFTER →
  RESTORE); a gate that cannot exit 1 is vacuous.

Standing vocabulary: `ALIVE` / `PARTIAL_ALIVE` / `PASS` / `SUSPECT` /
`FAIL` / `SKIP(<reason>)` / `UNSUPPORTED(<reason>)` — a status without
embedded real command output is `SUSPECT` by `receipt_index.py`, never
`PASS`.

Every wave ends with: (1) a witness receipt in `popcorn_demo/receipts/`
with real output, and (2) build-root reclamation via `popcorn-lane-clean`
— an integration commit that leaves new `_build-*` dirs is incomplete.
