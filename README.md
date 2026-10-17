# Smalt

**Sovereign local Azure substrate.** Pure-Elixir, BEAM-native emulator of the
Azure control/data plane for local development and testing: ARM-style control
plane on **9443**, TLS twin on **9444**, data plane on **8443**, AMQP Service
Bus on **5672**, Event Hubs on **5673**, read-only MCP tool surface on
**9545**. Point SDKs, CLIs, and Terraform-style tooling at loopback — no cloud
connection, no host configuration for the native tier.

Badges: native tier green · wire-parity tier opt-in (trust gate).

See `NOTICE.md` for the clean-room interoperability and trademark statement,
and `LICENSE` (Apache-2.0) for terms.

## Quickstart (verified golden path)

```sh
git clone <this-repo>
cd smalt
bash scripts/bootstrap.sh   # 8 idempotent stages; ends with GREEN
just                        # doctor + full native lifecycle (sub-200 ms)
just apply                  # provision the fixture through the native engine
just verify                 # read-your-write parity + zero-drift audit
just destroy                # cascade destroy; fails on any residue
```

`just` with no arguments is the default recipe: `doctor` first, then the
native lifecycle test. `just apply` parses unmodified `azurerm` HCL
(`test/terraform_fixture`), provisions through the in-process engine on a
private beam (ports 29445-29450), and writes
`tmp/native-enclave-state.json`. Standing receipt:
`docs/jira/v26.10.16/sdk-results/native-lifecycle.md`
(all six lifecycle stages sub-100 ms; max apply 52 ms).

Fresh-machine prerequisites: `brew install elixir terraform just` (python3
ships with macOS). Details: `docs/FIRST_RUN.md`; env template:
`.env.example`.

## Hex package vs repository

The hex package ships the runtime surface only: `lib/` and `priv/` (plus
`mix.exs`, docs, and license files). Repository-only tooling is not packaged:
`scripts/`, `docs/`, `justfile.d/`, `test/`, and the `Justfile` itself. If you
need the benches, courts, bootstrap script, or test suites, clone this
repository and run them from the checkout.

## Two tiers

| Tier | What it is | Trust setup | Entry |
|---|---|---|---|
| Native (primary) | in-process engine, raw azurerm HCL, zero-touch | none | `just apply` |
| Wire (opt-in) | terraform, azurerm 4.54.0, TLS twin | trust shim | `just apply tier=wire` |

The wire tier is gated fail-closed: without a PASS trust status it exits
`REFUSED[TIER-WIRE-UNAVAILABLE]` rather than degrading silently. Details:
`docs/TERRAFORM_TRUST.md`.

## Pointer map (Diátaxis tree)

The docs tree is being restructured into the four Diátaxis quadrants
(`docs/tutorials/`, `docs/how-to/`, `docs/reference/`,
`docs/explanation/`). Current canonical surfaces, and their planned homes:

| Document | Today | Diátaxis home |
|---|---|---|
| First-run walkthrough | `docs/FIRST_RUN.md` | `docs/tutorials/first-run.md` |
| Daily dev loop | **LANDED**: `docs/how-to/dev-loop.md` | same |
| Auth modes, STS, CORS | this README (Authentication) | `docs/how-to/auth.md` |
| Just recipes | `docs/JUST_REFERENCE.md` | `docs/reference/just.md` |
| Error codes (generated) | `docs/ERROR_CODES.md` | `docs/reference/error-codes.md` |
| Architecture | **LANDED**: `docs/explanation/architecture.md` | same |
| Wire parity / KD register | `docs/WIRE_PARITY.md` | `docs/explanation/wire-parity.md` |
| Terraform trust | `docs/TERRAFORM_TRUST.md` | `docs/explanation/terraform-trust.md` |
| PQC seal verification | **LANDED**: `docs/how-to/how-to-verify-pqc-seals.md` | same |
| affidavit-wasm surface | **LANDED**: `docs/reference/reference-affidavit-wasm.md` | same |

Until the restructure lands, the "Today" column is the live path.

## SDK smoke harness environment

No `npm install` in this repo: the Azure SDKs are consumed from an existing
`node_modules` tree via environment variables.

- `SMALT_SDK_ROOT` — required by every `test/sdk-smoke` harness: a
  `node_modules` directory containing the vendored `@azure/*` packages
  (`storage-blob`, `cosmos`, `service-bus`, `event-hubs`). Unset, the harness
  exits 3 immediately.
- `SMALT_REPO` — repo root for `run.mjs`, `census-run.mjs`, and
  `scripts/mutation_court.py`; defaults to the current directory.

```sh
SMALT_SDK_ROOT=/path/to/node_modules SMALT_REPO=/path/to/smalt \
  node test/sdk-smoke/run.mjs
```

The Event Hubs leg (`node test/sdk-smoke/eh-run.mjs`) and the Service Bus
census (`node test/sdk-smoke/census-run.mjs`) boot their own substrate;
`eh-run.mjs` defaults to alternate ports (19443/18443/15672/15673,
override with `SMALT_EH_ARM_PORT`/`SMALT_EH_EGRESS_PORT`/
`SMALT_EH_AMQP_PORT`/`SMALT_EH_PORT`) so it can run beside other tiers.

## Authentication

All HTTP planes honor `config :smalt, :auth_mode`:

- `:enforce` (default) — every non-exempt route on `:9443`/`:8443` requires
  a valid `Authorization: Bearer` HS256 token signed with the same STS
  secret (`Smalt.Auth.Bearer`, exp/aud/iss checked; 401 + ARM error envelope
  otherwise). The Cosmos plane additionally validates master-key
  Authorization headers (real string-to-sign HMAC) and applies an optional
  RU throttle (`config :smalt, :cosmos_ru_limit`); the ARM plane applies a
  fixed-window 429 throttle with `Retry-After`.
- `:anonymous` — explicit opt-out (the test suite sets it).

Two auth details worth knowing in enforce mode: `x-forwarded-*` headers are
honored only from configured trusted proxies
(`config :smalt, :trusted_proxies`) and ignored on direct connections
(fail-closed); and the STS's cross-seat trusted-authority set is VM-local
(`:persistent_term`), so a substrate restart wipes it — pre-restart tokens
minted at a sibling seat are refused after restart (restart implies
re-authentication).

Exempt paths: `/oauth2/*`, `/.well-known/*`, `/metadata/endpoints`,
`/common/discovery/*`, `/tenant(s)`, `/attest/*`.

CORS on the 8443 data plane is configurable via
`config :smalt, :egress_cors_origins` (list of exact origins). The default is
`["*"]` — the documented dev posture for the emulator; in production configure
an explicit allowlist (a non-listed origin receives no allow-origin header).

## Verification ladder

| Tier | Command | What it proves |
|---|---|---|
| T0 | `just doctor` | environment and ports are sane before anything runs |
| T1 | `just test-offline` (`mix test`) | unit suite, no sockets |
| T2 | `just test-wire` (`mix test test/wire`) | wire-tier protocol behavior over real listeners |
| T3 | `just test-sdk-smoke` | real SDK clients vs harness-spawned substrate |
| T4 | `just tf-plan-smoke` | terraform fixture plans against the substrate |
| T5 | `node test/sdk-smoke/census-run.mjs` | Service Bus SDK census probes vs the AMQP surface |
| T6 | `mix test test/chaos` | crash isolation: kill the Store mid-run, listeners survive |
| — | `node test/sdk-smoke/eh-run.mjs` | Event Hubs SDK probes on dedicated alternate ports |
| — | `mix test test/compliance/c1_arm.exs` (+ c2..c7) | per-service wire-contract courts |
| — | `python3 scripts/mutation_court.py` | GraphLaw admission gate non-vacuous |
| — | `python3 scripts/bench.py` + `just bench-check` | PRD perf CTQs hold, fresh bench receipt |
| — | `just gate` | T0..T4 plus the bench gate in sequence; full court |

(T3/T5 need `SMALT_SDK_ROOT` — see the harness environment section above.)

All port-bound tiers (T3-T5, terraform, bench, mutation court) boot
their own substrate; run them one at a time with the ports free.

## Benchmarks

```sh
python3 scripts/bench.py    # measures CTQs against a substrate it spawns (ports must be free)
just bench-check            # asserts tmp/bench-receipt.json against PRD thresholds
```

Gate thresholds: doctor <= 3s, boot p95 <= 5s, ARM PUT p95 < 50ms, Cosmos
round-trip p95 < 20ms, AMQP first frame < 100ms.

## Mutation court

```sh
python3 scripts/mutation_court.py              # boots its own substrate on 9443
python3 scripts/mutation_court.py --self-check # restore-failure detection only
```

Proves the GraphLaw admission gate (`lib/smalt/graphlaw/validator.ex`)
is non-vacuous by injecting a marked gate-bypass mutation, re-probing,
and restoring the file byte-exact (sha256-verified). Exit 0
non-vacuous, 1 vacuous/failed, 2 blocked.

## Compliance courts

Seven per-service courts fence the wire contract against real HTTP/AMQP
traffic (no doubles): `test/compliance/c1_arm.exs` ... `c7_events.exs`,
receipts in `docs/compliance/C1_ARM_REST.md` ... `C7_EVENT_PLANES.md`.

```sh
mix test test/compliance/c1_arm.exs          # c2..c7 likewise
mix test test/compliance/c5_servicebus.exs --include amqp_wire
```

## Stress suite

Load/chaos harnesses under `scripts/stress/` (soak, spike, TLS churn,
AMQP throughput/fanout, ARM scale, blob scale, cosmos bulk, LRO storm,
YCSB-lite, azurite comparison, telemetry overhead, chaos kill, gate cost),
receipts in `docs/STRESS/`. Just recipes: `just soak`, `just spike`,
`just tls-churn`; the rest run as `python3 scripts/stress/<harness>.py`
or `mix run scripts/stress/<driver>.exs`.

The authoritative measured-bounds table lives in `docs/STRESS/BOUNDS.md`,
gated fail-closed by `python3 scripts/stress/bounds.py`.

## Layout

- `lib/smalt/` — gateway, egress router, AMQP broker, Event Hubs, store
  (keyed ETS + DETS mirror; atomic `compare_and_swap` transitions).
- `lib/smalt/enclave/` — native lifecycle: `Hcl.parse/1`, `Engine.apply/2`
  (in-process ARM router, no terraform), `State.plan/destroy`,
  zero-drift and residue audit.
- `lib/smalt/mcp/` — read-only MCP tool surface on `:9545`:
  generated tool descriptor with `readOnlyHint`, real Store reads, actuation
  refused by name.
- `lib/smalt/ocel/` — object-centric event log registry, conformance
  (fitness + deviations), and deviation admission.
- `lib/smalt/pplan/` — durable P-PLAN task store: court-validated
  `admitted -> running -> succeeded | failed` transitions, exclusive CAS
  claim, crash recovery.
- `lib/smalt/projection/` + `lib/smalt/semantic/` — semantic projection
  surface. See `docs/SEMANTIC_PROJECTION.md`.
- `cli/` — `smaltctl` Rust CLI generated from `cli/ontology.ttl`
  (`cd cli && cargo test`).
- `test/` — offline, wire, SDK-smoke, census, terraform-fixture, and chaos
  tiers; `test/enclave-testbed/` — composite enclave-grade stress testbed
  (`bash test/enclave-testbed/run.sh`; 9 phases, 9 PASS standing).

## Workspaces & tooling

- `workspace/` — Sovereign Console: air-gapped Next.js evaluation console;
  only `127.0.0.1` endpoints are reachable. `just ws-install` / `ws-build` /
  `ws-lint` / `ws-court` / `ws-converge`.
- `smalt-cli/` — headless Python CLI companion; zero-actuation gate (AU-10)
  and four-gate verification runner (`smalt-cli/GATES.md`).
- `test/sdk-full` / `test/sdk-smoke` / `test/sdk-python` — real official
  Azure SDK probes. `just test-sdk-smoke`; `just census` (needs
  `SMALT_SDK_ROOT`).
- DoD tooling: `just court-x2`, `publish-dry`, `verify-all`, `sdk-matrix`,
  `substrate-up/down/status`, `doctor-dod`, `gap-sync`, `receipt-index`,
  `docs-dod-check`, `lane-clean`.

## Legal

Smalt is an independent, clean-room implementation of publicly documented
wire protocols for local testing. It is not affiliated with, sponsored by,
or endorsed by any cloud provider. Product and company names appearing in
protocol strings are trademarks of their owners, used solely for protocol
compatibility. See `NOTICE.md`.

## See Also

- `docs/tutorials/` — first-run and lifecycle walkthroughs
- `docs/how-to/` — task guides (dev loop, wire-parity runs)
- `docs/reference/` — generated surfaces (ports, error codes, just recipes, KD pointer)
- `docs/explanation/` — architecture and model explanations
