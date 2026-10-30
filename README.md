# Smalt

**Sovereign local Azure substrate.** Pure-Elixir, BEAM-native emulator of the
Azure control/data plane for local development and testing: ARM-style control
plane on **9443**, TLS twin on **9444**, data plane on **8443**, AMQP Service
Bus on **5672**, Event Hubs on **5673**, read-only MCP tool surface on
**9545**. Point SDKs, CLIs, and terraform-style tooling at loopback — no cloud
connection, no host configuration for the native tier.

See `NOTICE.md` for the clean-room interoperability and trademark statement,
and `LICENSE` (Apache-2.0) for terms.

## Standing (honest, as of 2026-10-18)

- **PQC attestation: GAP_TYPED, NOT_CLOSED** — KD-89 OPEN, witness-PENDING.
  The attestation surface is classical-only (SHA-256 Merkle + RS256 JWS,
  tamper-proven); the mounted affidavit-wasm engine has **no ML-DSA-65 verify
  op** — `verify_signature` supports only ES256/ES256K/Ed25519; `ML_DSA65`
  returns `unsupported_algorithm` upstream. What is live: the CTRT seal path
  (PQC-free by construction) and classical verify adjudication; the `:pqc`
  trust profile refuses typed (`{:refused, :PQC_NOT_PROVISIONED, _}`,
  `lib/smalt/trust_profile/trust_profile.ex:62`). No forge-verify court has
  run; none is claimed. What is green with receipts: the seal and verify-op
  courts plus `just doctor`
  (`docs/jira/v26.10.16/receipts/r215-affidavit-seal-court.md`: 113 tests,
  0 failures, forge rejections typed).
- **PUBLISH-READY: NO — TYPED-BLOCKED** (six evidence-cited blockers B1–B6;
  `docs/jira/v26.10.16/PUBLISH_RECORD.md`).
- **Court verdict, current**: the most recent court-x2 wrap runs are
  **RED — no two-green** (shifting-failure flake family in the semantic
  projection suite;
  `docs/jira/v26.10.16/receipts/r216-court-x2-run12-red.md`). The offline
  tier is stable green (2x 120/0 on a quiet tree); the flake family and the
  `appconfig-etag-cas` gate (DEF-2) are the open typed defects.

## Part 1 — Hex package (`lib/` + `priv/`)

The hex package ships the runtime surface only: `lib/` and `priv/` (plus
`mix.exs`, `README.md`, `LICENSE`, `CHANGELOG.md`, `NOTICE.md`).
Repository tooling — `scripts/`, `docs/`, `test/`, `justfile.d/`, the
Justfile — does not ship; clone the repository for it.

### Ports and planes

| Plane | Default port | Config key | Entry module (file:line) |
|---|---|---|---|
| ARM control | 9443 | `:arm_port` | `Smalt.ArmGateway.Router` — `lib/smalt/arm_gateway/router.ex:1` |
| ARM TLS twin | 9444 | `:arm_tls_port` | TLS twin dispatch — `lib/smalt/application.ex:130` |
| Data plane (egress) | 8443 | `:egress_port` | `Smalt.EgressRouter` — `lib/smalt/egress_router.ex:1` |
| Service Bus (AMQP) | 5672 | `:amqp_port` | `Smalt.AmqpBroker` — `lib/smalt/messaging/amqp_broker.ex:1` |
| Event Hubs | 5673 | `:event_hubs_port` | `Smalt.Messaging.EventHubs` — `lib/smalt/messaging/event_hubs.ex:1` |
| MCP tools | 9545 | `:mcp_port` | `Smalt.Mcp.Router` — `lib/smalt/mcp/router.ex:1` |

### Authentication

All HTTP planes honor `config :smalt, :auth_mode`:

- `:enforce` (default) — HS256 Bearer from the emulator STS
  (`Smalt.Auth.Bearer`, `lib/smalt/auth/bearer.ex:1`), exp/aud/iss checked,
  401 + ARM error envelope otherwise. The Cosmos plane additionally validates
  master-key Authorization headers (real string-to-sign HMAC) and applies an
  optional RU throttle (`config :smalt, :cosmos_ru_limit`); the ARM plane
  applies a fixed-window 429 throttle with `Retry-After`
  (`config :smalt, :arm_rate_limit`).
- `:anonymous` — explicit opt-out (the test suite sets it).

Enforce-mode details: `x-forwarded-*` headers are honored only from
`config :smalt, :trusted_proxies` and ignored on direct connections
(fail-closed); the STS cross-seat trusted-authority set is VM-local
(`:persistent_term`), so a substrate restart wipes it — restart implies
re-authentication. CORS on the 8443 data plane is
`config :smalt, :egress_cors_origins` (default `["*"]`, the documented dev
posture; configure an explicit allowlist otherwise). Exempt paths:
`/oauth2/*`, `/.well-known/*`, `/metadata/endpoints`, `/common/discovery/*`,
`/tenant(s)`, `/attest/*`.

### Quickstarts by subsystem

Entry-point-first, with the real config keys each surface reads and its typed
refusal behavior.

#### Native enclave lifecycle (primary tier)

Entry: `Smalt.Enclave.Engine.apply/2` (`lib/smalt/enclave/engine.ex:55`) over
`Smalt.Enclave.Hcl.parse/1` (`lib/smalt/enclave/hcl.ex:47`) output.
Read-your-write through `Smalt.Store` (keyed ETS + DETS mirror; atomic
`compare_and_swap/4`, `lib/smalt/store.ex:250`).

Config keys: `:lro_delay_ms`, `:lro_retention_ms`, `:doctor_supervisor`.
Typed refusal: the wire tier is gated fail-closed — without a PASS
trusted-machine gate it exits `REFUSED[TIER-WIRE-UNAVAILABLE]` (exit 3),
never degrades silently (`docs/how-to/how-to-run-wire-parity.md`).
Walkthrough: `docs/tutorials/enclave-lifecycle.md`.

#### ARM gateway (9443)

Entry: `Smalt.ArmGateway.Router` (`lib/smalt/arm_gateway/router.ex:1`), with
LRO orchestration (`lib/smalt/arm_gateway/lro.ex:1`) and a
`Sweeper` (`lib/smalt/arm_gateway/lro_sweeper.ex:1`) draining
`:lro_retention_ms` state. Config keys: `:arm_port`, `:arm_rate_limit`,
`:lro_delay_ms`, `:lro_retention_ms`, `:lro_sweep_interval_ms`,
`:rg_token_preserve_options`. Admitted api-version eras are fenced by
`Smalt.Metrics.version_admitted?/1`
(`lib/smalt/metrics.ex:35`); an unadmitted era refuses. Reference:
`docs/reference/arm-gateway.md`.

#### Data plane (8443)

Entry: `Smalt.EgressRouter` (`lib/smalt/egress_router.ex:1`) dispatching the
`lib/smalt/data_plane/` services (Blob, Cosmos, Key Vault, KQL, Purview,
Resource Graph, Sentinel, SKR, VaultData). Config keys: `:egress_port`,
`:blob_account_key`, `:blob_catch_all_hosts`, `:cosmos_master_key`,
`:kv_master_secret`, `:skr_allow_legacy_header`, `:eventgrid_response_mode`,
`:sentinel_dcr_strict`, `:sentinel_forensic`, `:maa_measurement_baseline`,
`:ledger_enforce_existence`. Reference:
`docs/reference/egress-data-plane.md`.

#### Service Bus (5672)

Entry: `Smalt.AmqpBroker` (`lib/smalt/messaging/amqp_broker.ex:1`) — CBS/SAS
auth over `:sb_endpoint` with the HMAC key pinned by `:sb_shared_key`
(nil = generated dev key cached in `:persistent_term`); AMQP tunneled
through `Smalt.SbRules` over `:amqp_port`. Config keys: `:sb_endpoint`,
`:sb_shared_key`, `:amqp_port`, `:amqp_sweeper_tick_ms`,
`:amqp_sweeper_lock_grace_ms`.

#### Event Hubs (5673)

Entry: `Smalt.Messaging.EventHubs` (`lib/smalt/messaging/event_hubs.ex:1`):
`send_event/3` (`lib/smalt/messaging/event_hubs.ex:75`),
`receive_events/3` (`:267`), checkpoint compare-and-swap
(`:341`), lease `reserve_processing/4` (`:380`), `reconcile/3`
(`:392`). Config keys: `:event_hubs_port`, `:event_stream_dedup_ids`.
Fixed partition set `["0", "1"]` — pinned by a real-SDK census;
changes regress real handshakes.

#### MCP surface (9545)

Entry: `Smalt.Mcp.Router` (`lib/smalt/mcp/router.ex:1`). Read-only tool
surface: every tool descriptor carries `readOnlyHint` (`:214`), and any
mutating call is answered with the typed code `ACTUATION_REFUSED`
(`:71`) rather than executed. Config key: `:mcp_port`.

#### Affidavit / evidence seal

Entry: `Smalt.Affidavit.Seal.admit_and_seal/2`
(`lib/smalt/affidavit/seal.ex:37`) — canonical JSON, SHA-256 Merkle, RS256
JWS (classical-only; see the Standing block). The WASM engine surface
(`Smalt.Affidavit.WasmEngine.call/2`,
`lib/smalt/affidavit/wasm_engine.ex:159`) returns a typed
engine-unavailable result when the engine is down;
`call_admit_and_seal/4` (`:234`) is the admitted-transition entry.
Config keys: `:affidavit_wasm_path`, `:affidavit_wasm_pin_path`,
`:receipt_signing_key`. Forge refusals are typed:
`{:error, {:invalid_receipt, field}}` host-side; the engine answers
`unsupported_algorithm` for `ML_DSA65` (KD-89, open). Reference:
`docs/reference/reference-affidavit-wasm.md`.

#### Trust profiles

Entry: `Smalt.TrustProfile.profile/1`
(`lib/smalt/trust_profile/trust_profile.ex:93`). `:classical` is
provisioned; `:hybrid` and `:pqc` refuse typed
(`{:refused, :PQC_NOT_PROVISIONED | :HYBRID_NOT_PROVISIONED, _}`, `:62`,
`:104`) — no PQC is ever faked. Deployment surface:
`lib/smalt/trust_profile/deployment.ex`.

#### OCEL / telemetry

Entry: `Smalt.Ocel.EventRegistry` (`lib/smalt/ocel/event_registry.ex:6`),
conformance fitness (`lib/smalt/ocel/conformance.ex:168`), deviation
admission (`lib/smalt/ocel/deviation_admission.ex`). Telemetry contract:
`Smalt.Telemetry.SemConv.Registry`
(`lib/smalt/telemetry/semconv/registry.ex:1`), NDJSON emission via
`lib/smalt/telemetry/ocel_ndjson.ex`. Config keys: `:ocel_dir`.

#### GraphLaw admission

Entry: `Smalt.GraphLaw.Validator` (`lib/smalt/graphlaw/validator.ex:1`).
Config key: `:graphlaw_engine`. Non-vacuity is court-proved, not asserted —
see Mutation court in Part 2.

GL28-2 (v26.10.28) adds a second, fail-closed gate in front of the ARM
router: `Smalt.GraphlawEx.AdmissionGate`
(`lib/smalt/graphlaw_ex/admission_gate.ex`) — enabled with
`config :smalt, :graphlaw_ex_gate, enabled: true` (on in dev/test; default
off in prod), it refuses with a typed refusal when the engine digest is nil.
The gate rides `graphlaw_ex` as a path dependency
(`mix.exs`: `{:graphlaw_ex, path: "../graphlaw/graphlaw_ex"}`) — a fresh
clone needs the sibling `graphlaw` checkout to compile.

## Part 2 — Repository

### Bootstrap (fresh machine)

```sh
git clone <this-repo>
cd smalt
brew install asdf just terraform     # python3 ships with macOS / Xcode CLT
asdf plugin add elixir erlang && asdf install   # .tool-versions pins elixir 1.20.4-otp-29 / erlang 29.1.2 — Homebrew elixir (1.19.x) is refused (mix.exs: elixir "~> 1.20")
bash scripts/bootstrap.sh            # 8 idempotent stages; exit 1 names the failed [n/8] stage
```

Stages: prerequisites (elixir/mix/terraform/just/python3) → hex deps →
compile → dev-environment check → TLS material (`scripts/gen_dev_cert.sh`) →
doctor `--fix` (`scripts/doctor.py`) → boot smoke (substrate up →
`GET /metadata/endpoints` → teardown) → proof test (`mix test
test/smalt_test.exs`). Port-bound stages need 9443 and 9545 free.
Env template: `.env.example`; details: `docs/FIRST_RUN.md`.

### Courts ladder

| Tier | Command | What it proves |
|---|---|---|
| T0 | `just doctor` | environment and ports are sane before anything runs |
| T1 | `just test-offline` (`mix test`) | unit suite, no sockets |
| T2 | `just test-wire` | RETIRED (v26.10.19 reset 64f6099): exits 1 loudly; successor = verification/ suites (V261019-08/09) |
| T3 | `just test-sdk-smoke` | RETIRED (64f6099): exits 1 loudly; successor = verification/ts (V261019-08) |
| T4 | `just tf-plan-smoke` | terraform fixture plans against the substrate (exit 77 = SKIPPED-NETWORK, rerun online) |
| T5 | `just census` | Service Bus SDK census probes (`verification/ts/census.test.cjs`, live AMQP; exit 0/1) |
| T6 | `just test-stress` (`mix test --include stress`) | crash isolation + expensive bodies (excluded from plain `mix test`) |
| — | `mix test test/compliance/c1_arm.exs` (+ c2..c7) | per-service wire-contract courts |
| — | `python3 scripts/mutation_court.py` | GraphLaw admission gate non-vacuous (exit 0/1/2; `--self-check` for restore-failure detection) |
| — | `just court` | T0..T4 + bench gate in sequence; full court |
| — | `just court-x2` | two-green release receipt gate (~8 min) |
| — | `just verify-all` | offline stages only |
| — | `just have-watchdog` | HAVE L1 pool-saturation guard (exit 0 quiet / 1 alerts fired / 2 config) |

All port-bound tiers boot their own substrate; run one at a time with the
ports free. Current verdict for the heaviest gates is in the Standing block
above — this table names commands, not pass states.

### Invariant gates

Six fail-closed gates with negative-fixture contracts under `gates/`
(`just invariant-gates`): cosmos-etag-cas, appconfig-etag-cas, blob-worm,
ledger-chain, queue-capacity, lock-clamp. A gate that cannot exit 1 is the failure; each
verdict must REFUSE a mutated observation, never silently pass.

### Shim courts

`scripts/shim_court/<name>_court.sh` — BASELINE → BEFORE → SHIM (marker
`SHIM-COURT` mandatory) → AFTER (the flip IS the non-vacuity proof) →
RESTORE (sha256 byte-exact, fail-closed). `just shim-court <name>` /
`just shim-courts`. Exit 0/1/3; a skip is loud, never a faked pass. A shim
landed in `lib/` carries `# KD-COVERS: KD-nn`; register flips go through
`scripts/kd_flip.py --apply`, gated on a witness receipt newer than the
shim's mtime.

### Benches

```sh
python3 scripts/bench.py    # measures CTQs against a substrate it spawns (ports must be free)
just bench-check            # asserts tmp/bench-receipt.json against PRD thresholds
```

Gate thresholds: doctor <= 3s, boot p95 <= 5s, ARM PUT p95 < 50ms,
Cosmos round-trip p95 < 20ms, AMQP first frame < 100ms. Lane registry and
port law: `scripts/bench/REGISTRY.md`; stress harnesses under
`scripts/stress/` with the authoritative measured-bounds table in
`docs/STRESS/BOUNDS.md` (fail-closed via `python3 scripts/stress/bounds.py`).

### Planes (SMALT_PLANES)

`SMALT_PLANES` (comma list) or `config :smalt, :planes` selects a boot
subset of the planes `control,data,integration,identity` (`:all` default,
byte-identical boot). Unknown names refuse boot with
`{:invalid_plane, name}` (`lib/smalt/planes.ex:38`; loader receipt
`docs/jira/v26.10.18/receipts/azb-04-plane-loader.md`). Plane-profile SDK
interop: `just azsim-sdk` is RETIRED (test/sdk-full/azb20 deleted at 64f6099;
exits 1 loudly until the verification/ts successor lands, V261019-08).

### azsim tier

RETIRED: `test/azsim/` was deleted in the v26.10.19 reset (64f6099). The
10-file adversarial plane-topology suite (saturation, graceful stop, DETS
recovery, identity/integration planes, supervision) and its chaos legs
(AZB-14 SIGKILL storm,
`docs/jira/v26.10.18/receipts/azb-14-sigkill-storm.md`) are historical
receipts only — no successor lane has landed.

### Burn suite

Docker burn lanes under `docker/burn/` driven by `justfile.d/30-burn.just`:
`just burn-soak` / `burn-chaos` / `burn-matrix` / `burn-ring` /
`burn-boot` (AZB-13, 50 boot/probe/teardown cycles per plane,
`docs/jira/v26.10.18/receipts/azb-13-boot-burn.md`) / `burn-chaos-kill`
(AZB-14 SIGKILL storm, sabotage-mode anti-vacuity) / `burn-ocel`
(OCEL 2.0 projection) / `burn-clean`. Image receipt:
`docs/jira/v26.10.18/receipts/burn-image.md`.

### Stress tier

The `:stress` tag carries the expensive test bodies (replay-identity
fences, DETS churn, 10k-op fuzz, 1000-PUT corpus sweep), excluded from
plain `mix test` by `test/test_helper.exs`. `just test-stress`
(`mix test --include stress`) runs them sequentially; population fence
`test/stress_tier_census_test.exs`. Measured-bounds table:
`docs/STRESS/BOUNDS.md` (fail-closed via `python3 scripts/stress/bounds.py`).

### Budget gate

`just test-budget-seed` records the per-test timing manifest; every
`just test-budget` run re-exports timings and fail-closed-checks
regression above budget, deleted/renamed tests, and unbudgeted new tests
(`scripts/test_budget_gate.py`; design
`docs/jira/v26.10.18/rewrite-drafts/budget-gate.md`). Non-vacuity: mutated
fixtures run through the same verdict — an ACCEPTED mutation is VACUOUS
GATE, exit 1.

### HAVE supervisory engine

HAVE (L1) keeps the ~20-lane wave saturated: `pool_saturation_guard.py` counts
`pgrep -f 'mix test|docker'` workers against the target pool (20) and emits
typed `have_worker_fleet_active_count` jidoka alerts + dispatch requests on
deficit (it requests, never spawns). Telemetry catalog (ledger row kinds,
alert severity ladder) and crontab templates:
`docs/reference/have-runbook.md`; recipes `just have-*`
(`justfile.d/31-have.just`); ledger under `tmp/have/` (gitignored).

### Zero-sleep doctrine

`Process.sleep` is not acceptable test or production methodology: tests
poll observables via `SmaltTest.AssertEventually`; `lib/` sleeps only as
SCHEDULING (`send_after`). Enforced fail-closed by `just sleep-gate`
+ `just sleep-gate-court` non-vacuity
(`docs/NO_SLEEP_DOCTRINE.md`; receipt
`docs/jira/v26.10.18/receipts/azb-21-zero-sleep.md`).

### Hex-only ex4pm

`ex4pm` resolves from hex.pm like every other dependency (path dep
retired, operator ruling 2026-10-17, mix.exs; dry-build receipt in
`docs/jira/v26.10.16/PUBLISH_RECORD.md`). `ash_ex4pm` stays a
dev/test-only optional dep (`mix.exs:107`).

### SmaltTest foundations

`SmaltTest.Case` (`test/support/case.ex`) is the canonical base for
new/migrated suites: one `use` imports `AssertEventually`, `Env`, `Store`,
and `Singleton.start_supervised_singleton!/2`. Migration is per-file and
optional — plain `use ExUnit.Case` keeps working. Isolation rules:
`docs/TEST_ISOLATION.md`.

### KD register

Divergences get a `KD-nn` row in
`docs/jira/v26.10.16/KNOWN_DIVERGENCES.md` (surface, divergence, evidence
receipt, close condition); the canonical pointer is
`docs/reference/kd-register.md`. `GAP(name)` tokens in `docs/WIRE_PARITY.md`
name OPEN gaps and disappear only with a closing receipt. Never mint new GAP
tokens unilaterally.

### Wrap sequence

Lanes land per dependency order → receipt-gated register flips → fin sweep →
regenerate all generated artifacts (`docs/ERROR_CODES.md`, `RECEIPTS.md`,
`receipts/INDEX.md`, `BENCH_RESULTS.md`, `SDK_MATRIX.md` — never hand-edited)
→ `just court-x2` → commits (`git commit -F <file>`) → `just publish-dry` →
`FINAL.md` with a planning handoff to the next window. DoD gate:
`just docs-dod-check` (every receipt path named in user-facing docs must
exist on disk).

### SDK probe harness environment

RETIRED with the v26.10.19 reset (64f6099): the `test/sdk-smoke/` harnesses
were deleted. Successor: `verification/ts` (V261019-08) — the landed Service
Bus census probes run via `just census`. Environment contract to restore
when the full successor harness lands: `SMALT_SDK_ROOT` (node_modules with
vendored `@azure/*`; relay-env exports it when present) and `SMALT_REPO`
(repo root; defaults to cwd).

## Capability map (entry points, cited)

| Capability | Entry point (file:line) | Notes |
|---|---|---|
| ARM gateway | `lib/smalt/arm_gateway/router.ex:1` | 9443 control plane; LRO at `lib/smalt/arm_gateway/lro.ex:1` |
| Egress data plane | `lib/smalt/egress_router.ex:1` | 8443; Blob/Cosmos/KV/KQL/Sentinel under `lib/smalt/data_plane/` |
| Cosmos SQL | `lib/smalt/cosmos_sql.ex:72` | `parse/2` + `eval_docs/2` (`:94`), `run/3` (`:112`) |
| AMQP broker | `lib/smalt/messaging/amqp_broker.ex:1` | 5672 CBS/SAS |
| Event Hubs | `lib/smalt/messaging/event_hubs.ex:75` | `send_event/3`; leases `:380` |
| Event stream | `lib/smalt/messaging/event_stream.ex:1` | dedup via `:event_stream_dedup_ids` |
| Store | `lib/smalt/store.ex:250` | `compare_and_swap/4`; DETS mirror |
| Enclave engine | `lib/smalt/enclave/engine.ex:55` | `apply/2`; HCL `lib/smalt/enclave/hcl.ex:47` |
| Auth (Bearer) | `lib/smalt/auth/bearer.ex:1` | HS256 STS; `:auth_mode` |
| MCP (read-only) | `lib/smalt/mcp/router.ex:71` | `ACTUATION_REFUSED`; `readOnlyHint` `:214` |
| Affidavit seal | `lib/smalt/affidavit/seal.ex:37` | `admit_and_seal/2`; classical-only |
| Affidavit WASM | `lib/smalt/affidavit/wasm_engine.ex:159` | `call/2`; typed unavailable |
| Trust profiles | `lib/smalt/trust_profile/trust_profile.ex:93` | `:pqc`/`:hybrid` typed refusals |
| GraphLaw | `lib/smalt/graphlaw/validator.ex:1` | admission gate; mutation-courted |
| GraphLawEx gate | `lib/smalt/graphlaw_ex/admission_gate.ex:1` | ARM-router fail-closed gate; `:graphlaw_ex_gate` config |
| Policy | `lib/smalt/policy.ex:1` | deontic policy surface |
| OCEL registry | `lib/smalt/ocel/event_registry.ex:6` | fitness `lib/smalt/ocel/conformance.ex:168` |
| P-PLAN tasks | `lib/smalt/pplan/task.ex:1` | durable task transitions |
| SemConv | `lib/smalt/telemetry/semconv/registry.ex:1` | telemetry contract |
| Metrics | `lib/smalt/metrics.ex:35` | api-version era fence |
| Security/trust | `lib/smalt/security/receipt_signer.ex:1` | + attestation, confidential ledger, ledger writer |
| Runtime contracts | `lib/smalt/runtime_contracts.ex:1` | + `lib/smalt/runtime_contracts/` |
| Semantic projection | `lib/smalt/semantic/resource.ex:1` | + `lib/smalt/projection/` (`docs/SEMANTIC_PROJECTION.md`) |
| DSPy remediation | `lib/smalt/dspy/` | remediation surface |
| Ash extension | `lib/smalt/ash_extension/` | Ash integration surface |

## Repository layout (selected)

- `lib/smalt/` — runtime surface (Part 1)
- `workspace/` — Sovereign Console: air-gapped Next.js evaluation console;
  only `127.0.0.1` endpoints are reachable. `just ws-install` / `ws-build` /
  `ws-lint` / `ws-court` / `ws-converge`
- `smalt-cli/` — headless Python CLI companion; zero-actuation gate (AU-10)
  and four-gate verification runner (`smalt-cli/GATES.md`)
- `cli/` — `smaltctl` Rust CLI generated from `cli/ontology.ttl`
- `test/` — offline, wire, SDK-smoke, census, terraform-fixture, compliance,
  and chaos tiers; `test/enclave-testbed/` composite stress testbed
- `gates/` — invariant gates (negative-fixture contracts)
- `scripts/` — benches, shim courts, substrate manager, KD flip, doctor
- `docs/tutorials/` · `docs/how-to/` · `docs/reference/` ·
  `docs/explanation/` — Diátaxis tree

## Legal

Smalt is an independent, clean-room implementation of publicly documented
wire protocols for local testing. It is not affiliated with, sponsored by,
or endorsed by any cloud provider. Product and company names appearing in
protocol strings are trademarks of their owners, used solely for protocol
compatibility. See `NOTICE.md`.

## POSH — Go adapter membrane

POSH is the Go-side hyperscaler adapter membrane for smalt: a Go module
(`posh/`) that faces Azure ARM (and other hyperscaler SDKs) and talks to the
Elixir core over a BEAM↔posh membrane (UDS JSON framing today, gRPC later).
It replaces the archived Elixir Terraform provider spike
(`terraform-provider-smalt`, archived per POSH-007) with a Go Terraform
provider under `adapters/terraform-provider-smalt`.

```
+----------------+   UDS JSON membrane   +----------------------+
|  smalt (BEAM)  | <-------------------> |  posh (Go module)    |
|  lib/smalt/    |                       |  Azure ARM face      |
+----------------+                       +----------+-----------+
                                                    |
                                         +----------v-----------+
                                         | adapters/            |
                                         | terraform-provider-  |
                                         | smalt (protocol 6)   |
                                         +----------------------+
```

Quickstart (canonical — copy-paste-tested; the single onboarding path. All
other POSH docs point here):

```sh
colima start           # docker daemon for kind (idempotent)
just posh-doctor       # prereq + substrate physician; builds posh/bin if absent
just posh-court        # 7-stage DoD ladder; embeds kind-up/images/deploy + build + install
just posh-status       # report-only witness (exit 0 always)
```

Prerequisites: just, colima, kind, kubectl, Go 1.23+, Terraform >= 1.14 < 2.
asdf Elixir 1.20.4 only for BEAM-side tests (system mix 1.19.5 fails); `ggen`
optional (`posh-generate` only). Run everything from the repo root.

Landmines (details in `adapters/terraform-provider-smalt/README.md`
troubleshooting table): `/healthz` is bearer-gated — readiness anchor is
`/metadata/endpoints` (always-200); dev_overrides needs the TF >= 1.14
unlabeled attribute form (posh-install writes it); kind cluster name is
pinned `smalt` (config + `--name` agree); node disk fence 20000MB —
`just kind-prune` when `kind-images` refuses.

Design, orders, and receipts: `docs/jira/posh/v26.10.30/` (start at its
`README.md`).

## See Also

- `docs/tutorials/enclave-lifecycle.md` — first-run lifecycle walkthrough
- `docs/how-to/dev-loop.md` — daily dev loop
- `docs/reference/ports-and-planes.md` — port law
- `docs/reference/just-recipes.md` — recipe reference
- `docs/reference/kd-register.md` — KD canonical pointer
- `docs/explanation/architecture.md` — architecture
