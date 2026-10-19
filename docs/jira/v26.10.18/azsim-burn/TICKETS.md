# AZSIM-BURN Tickets — v26.10.18

Index/DAG/gate: [`README.md`](README.md). Base subject: `21f58b0`.
Every ticket: standing UNKNOWN until receipt `docs/jira/v26.10.18/receipts/azb-NN-<slug>.md`
lands with real command output + exact SHA. Diff budget ≤12 files per ticket.
All waits: `assert_eventually` / message passing / deadline polls. Zero `Process.sleep`, zero `sleep N` in shell.

Ticket fields: **Q** quadrant · **Lane** · **Deps** · **Scope** (files) · **Spec** ·
**Accept** (commands, exit codes) · **Falsifier** (observation that kills the claim) ·
**Anti-vacuity** (mutation that must make Accept fail) · **Receipt**.

---

## E1 — Burn Foundry (docker/)

### AZB-01 — Pinned warm image (OTP 28 + Elixir 1.19.5)
- **Q** REDUCE · **Lane** foundry · **Deps** —
- **Scope** `docker/Dockerfile`, `docker/BUILD_RECEIPT.md`
- **Spec** Pin base by digest (`hexpm/elixir:1.19.5-erlang-28.x-...@sha256:`). Layer order: `mix.exs`+`mix.lock` → `mix deps.get && mix deps.compile` (MIX_ENV=test and prod) → `lib/ config/ priv/` → `mix compile --warnings-as-errors`. Release target + test target from one Dockerfile (multi-stage). Image label `org.smalt.subject=<git sha>`.
- **Accept** `docker build -f docker/Dockerfile -t smalt:local .` exit 0; second build with only a `lib/` touch reuses the deps layer (`CACHED` on the deps step in `--progress=plain` output); `docker run smalt:local erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().'` prints `28`.
- **Falsifier** deps layer rebuilt after a `lib/`-only change; OTP ≠ 28; Elixir ≠ 1.19.5.
- **Anti-vacuity** bump a dep in `mix.lock` → deps layer must rebuild.
- **Receipt** `azb-01-image-pin.md` (digest, layer cache log, versions).

### AZB-02 — Per-container network namespaces, zero host port publish
- **Q** ELIMINATE · **Lane** foundry · **Deps** AZB-01
- **Scope** `docker/burn/compose.burn.yml`, `docker/compose.yaml`
- **Spec** Each burn service gets its own netns (default bridge per service or `network_mode: none` + loopback for single-plane cycles). No `ports:` publish in the burn project. Canonical ports 9443/9444/8443/5672/5673/9545 bind inside each container. Services: `smalt-burn-{control,data,integration,identity,all}-{1..N}` generated from a matrix spec, not hand-listed (template → compose; record UNSUPPORTED(generator-capability) if templated compose cannot be produced by ggen and hand-write once).
- **Accept** `docker compose -f docker/burn/compose.burn.yml config | grep -c 'published'` → `0`; N=4 matrix up: each container `ss -ltn` shows 9443 bound; host `lsof -iTCP:9443 -sTCP:LISTEN` empty.
- **Falsifier** any two containers' listeners conflict, or host shows a listener on a canonical port.
- **Anti-vacuity** add a `ports: ["9443:9443"]` to two services → preflight in `parallel-matrix.sh` must exit 2 with `HOST_PORT_PUBLISH_REFUSED`.
- **Receipt** `azb-02-netns.md`.

### AZB-03 — Burn JSONL receipt schema + validator
- **Q** CREATE · **Lane** foundry · **Deps** —
- **Scope** `docs/jira/v26.10.18/burn/burn-row.schema.json`, `scripts/validate_burn.py`, `docker/burn/*.sh` (row emitter only)
- **Spec** One row per (container, plane, cycle, stage). Required fields: `subject_sha`, `image_digest`, `container`, `plane`, `cycle`, `stage ∈ {boot,probe,chaos,recover,teardown,soak}`, `verdict ∈ {CLEAN,ORPHAN_LISTENER,ZOMBIE_BEAM,UNHANDLED_EXIT,DETS_UNREPAIRED,TYPED_VOCAB_MISMATCH,TIMEOUT_DEADLINE}`, `t_start`, `t_end`, `exit_code`, `orphans[]`, `crash_reports`, `evidence_path`, `broken_term` (null iff CLEAN). Rows written to `docs/jira/v26.10.18/burn/<run-id>.jsonl` (tracked, not tmp/ — avoids `R_missing_replay`). Validator `--gate` exits non-zero on: schema violation, missing (container,cycle,stage) cell in the expected matrix, any non-CLEAN row. Also validates each run summary against `~/.zcode/dfcm/receipt.schema.json`.
- **Accept** `python3 scripts/validate_burn.py --gate docs/jira/v26.10.18/burn/fixtures/clean.jsonl` exit 0; `.../fixtures/missing-cell.jsonl` exit 1; `.../fixtures/orphan.jsonl` exit 1.
- **Falsifier** a matrix with a dropped cycle passes `--gate`.
- **Anti-vacuity** delete one row from clean fixture → exit 1 with `MISSING_CELL container=… cycle=…`.
- **Receipt** `azb-03-burn-schema.md`.

---

## E2 — Azure Plane Profiles (config/env/)

### AZB-04 — Plane profile loader (`SMALT_PLANES`)
- **Q** CREATE · **Lane** planes · **Deps** —
- **Scope** `config/config.exs`, `config/runtime.exs` (new if absent), `config/env/az_prod_{control,data,integration,identity}.exs`, ontology config keys (`smalt:ck-plane*`) + regenerated `Smalt.Config` projection
- **Spec** `SMALT_PLANES` (comma list) or `config :smalt, :planes, [...]`; default `:all`. Each `config/env/az_prod_<plane>.exs` imported only when its plane is selected (runtime.exs, so releases honor it). Profile keys from the ARD (`:arm_gateway`, `:cosmos`, `:blob_storage`, `:amqp`, `:event_grid`, `:keyvault`, `:sts`, `:graph_law`) are declared in the ontology and projected into `Smalt.Config` accessors; existing flat keys (`:arm_port`, `:egress_port`, `:sb_endpoint`) remain authoritative — profile `port:` maps onto them (single source; no dual truth). Unknown plane name ⇒ boot refuses with `{:invalid_plane, name}`.
- **Accept** `mix compile --warnings-as-errors` 0; `SMALT_PLANES=identity mix run -e 'IO.inspect Smalt.Config.planes()'` → `[:identity]`; unset → `:all`; `SMALT_PLANES=bogus mix run -e ''` exits non-zero with `invalid_plane`; `mix test` green unchanged (count ≥ 2655, 0 failures).
- **Falsifier** default boot child list differs from `21f58b0` (diff `Supervisor.which_children(Smalt.Supervisor)` ids).
- **Anti-vacuity** remove the plane validation clause → `bogus` test must fail.
- **Receipt** `azb-04-plane-loader.md`.

### AZB-05 — Control plane profile (ARM)
- **Q** CREATE · **Lane** planes · **Deps** AZB-04
- **Scope** `config/env/az_prod_control.exs`, `lib/smalt/arm_gateway/*` (config read sites only), `test/azsim/control_plane_test.exs`
- **Spec** `:plane :control`; `:arm_gateway port: 9443, strict_version_validation: true`; `:graph_law enforcement: :fail_closed`. Strict mode: unknown `api-version` ⇒ ARM-shaped 400 `InvalidApiVersionParameter` / `NoRegisteredProviderFound` (reuse `rewrite-drafts/apiversion-refusal.md` vocabulary). `fail_closed`: graphlaw engine unavailable ⇒ typed `:engine_unavailable` refusal, never admit.
- **Accept** control-plane test: `PUT .../providers/Microsoft.Storage/storageAccounts/x?api-version=2021-12-02` → 200/201 with `x-ms-request-id`; `api-version=2099-01-01 (amended 2026-10-18, coordinator ruling: the original 1999 stale-version case contradicted the pinned KD-78 monotonic admission — operator ruling, ontology smalt:admitsVersion; refusal pins use a FUTURE version, never a past one. See CLAUDE.md corpus premise pins.)` → 400 typed; graphlaw engine killed → 503 `engine_unavailable`. `terraform plan` (azurerm, `ARM_METADATA_HOST` → plane) exit 0 on `test/fixtures/tf/basic`.
- **Falsifier** any request admitted while graphlaw engine is down.
- **Anti-vacuity** flip `enforcement: :fail_open` → engine-down test must fail.
- **Receipt** `azb-05-control-plane.md`.

### AZB-06 — Data plane profile (Cosmos SQL + Blob hot tier)
- **Q** CREATE · **Lane** planes · **Deps** AZB-04
- **Scope** `config/env/az_prod_data.exs`, `lib/smalt/data_plane/{cosmos,blob_storage,blob_service}.ex` (config read sites), `lib/smalt/store/dets_mirror.ex`, `test/azsim/data_plane_test.exs`
- **Spec** `:cosmos endpoint: "https://localhost:8443", max_ru_limit: :unbounded`; `:blob_storage persistence: :dets_mirrored, sync_interval_ms: 0` (0 ⇒ synchronous `:dets.sync` per write — durability for chaos AZB-14). If-Match contention: 6 concurrent replaces on one ETag ⇒ exactly `1×200 + 5×412`. Blob conditional `HEAD`/`GET` with `Range`, `If-None-Match`, `If-Modified-Since`.
- **Accept** data-plane test 6-way race asserts `{200:1, 412:5}` across 100 iterations; range GET returns 206 + correct `Content-Range`; `sync_interval_ms: 0` write then `kill -9` then reboot ⇒ object present.
- **Falsifier** any iteration yields ≠ 1 winner; acknowledged write lost after SIGKILL.
- **Anti-vacuity** replace ETag compare with unconditional write → race test must show >1×200.
- **Receipt** `azb-06-data-plane.md`.

### AZB-07 — Integration plane profile (Service Bus AMQP + Event Grid)
- **Q** CREATE · **Lane** planes · **Deps** AZB-04
- **Scope** `config/env/az_prod_integration.exs`, `lib/smalt/messaging/amqp_broker.ex` + `amqp/*` (config read sites), new `lib/smalt/messaging/event_grid.ex` (if absent), `test/azsim/integration_plane_test.exs`
- **Spec** `:amqp port: 5672, sasl_mechanisms: [:anonymous], max_frame_size: 65536`; `:event_grid delivery_mode: :at_least_once`. Frame > max ⇒ AMQP `amqp:frame-size-too-small`/connection close with typed error, no crash. DLQ on max-delivery-count; partition detach ⇒ `amqp:link:detach-forced` and clean relink. Event Grid: at-least-once with dedup key `id`; subscriber failure ⇒ redelivery, never loss.
- **Accept** integration test: send/receive/complete/abandon/deadletter round-trip; oversize frame typed close; Event Grid subscriber crash ⇒ redelivered event count ≥ 1, duplicates carry same `id`.
- **Falsifier** an Event Grid event published and never delivered after subscriber recovery.
- **Anti-vacuity** switch delivery to at-most-once (ack before dispatch) → loss test must fail.
- **Receipt** `azb-07-integration-plane.md`.

### AZB-08 — Identity plane profile (KeyVault + Entra STS)
- **Q** CREATE · **Lane** planes · **Deps** AZB-04
- **Scope** `config/env/az_prod_identity.exs`, `lib/smalt/auth/bearer.ex`, `lib/smalt/data_plane/{vault_data,key_vault_actions}.ex` (config read sites), `test/azsim/identity_plane_test.exs`
- **Spec** `:keyvault api_version: "7.4", challenge_mode: :strict_bearer`; `:sts token_ttl_seconds: 3600, pki_envelope: :pqc_hybrid`. KD-15 mode-blind challenge: unauthenticated KV call ⇒ 401 + `WWW-Authenticate: Bearer authorization="…", resource="https://vault.azure.net"` identically in `:enforce` and `:anonymous`. Expired token (TTL elapsed via injected clock, not sleep) ⇒ 401. Key rotation: new version issued, old version still decrypts, `GET /keys/{name}` returns latest.
- **Accept** identity test covers challenge shape (both auth modes, byte-equal header), injected-clock expiry, rotation; `azure-keyvault-secrets` SDK set/get round-trip.
- **Falsifier** challenge header differs between auth modes; expired token admitted.
- **Anti-vacuity** short-circuit challenge in `:anonymous` → KD-15 test must fail.
- **Receipt** `azb-08-identity-plane.md`.

### AZB-09 — Plane-scoped supervision subtrees
- **Q** CREATE · **Lane** planes (owns `application.ex` this wave, disclosed) · **Deps** AZB-05..08
- **Scope** `lib/smalt/application.ex`, new `lib/smalt/plane/{control,data,integration,identity}_supervisor.ex`, `test/azsim/plane_supervision_test.exs`
- **Spec** Partition the current child list into four plane supervisors (`Smalt.Plane.ControlSupervisor` ← ARM Bandit + TLS twin (ARM surface) + LRO Notifier/Sweeper + graphlaw/WasmEngine supervisor; `DataSupervisor` ← Store + egress Bandit; `IntegrationSupervisor` ← AmqpBroker; `IdentitySupervisor` ← KV/STS surface). Shared infra (Telemetry.RollingCounters, MCP) stays top-level. `:all` ⇒ all four started, order preserving today's start order (Store before listeners, Notifier before Sweeper). Each plane supervisor `one_for_one`, explicit restart intensity, registered name for `Supervisor.terminate_child/2`.
- **Accept** `Supervisor.which_children(Smalt.Supervisor)` lists the 4 plane supervisors under `:all`, only selected ones otherwise; full `mix test` green (count unchanged, 0 failures) ×2; `terminate_child(Smalt.Supervisor, Smalt.Plane.DataSupervisor)` leaves ARM serving 200.
- **Falsifier** killing one plane subtree causes any request on another plane to fail.
- **Anti-vacuity** put all planes under one `one_for_all` → isolation test must fail.
- **Receipt** `azb-09-plane-subtrees.md`.

### AZB-10 — Cross-plane wiring (loopback, zero egress)
- **Q** CREATE · **Lane** planes · **Deps** AZB-09
- **Scope** `config/env/*.exs` (peer endpoints), `lib/smalt/egress_router.ex` (peer resolution only), `test/azsim/topology_test.exs`
- **Spec** Planes discover peers by config (`:peers, identity: "https://127.0.0.1:9444", ...`) — same node ⇒ local call short-circuit is NOT allowed (must cross the wire for fidelity); separate containers ⇒ compose service DNS. Data/control planes validate bearer tokens minted by identity plane's STS (issuer + JWKS fetched from identity plane). Control-plane resource PUT emits Event Grid `Microsoft.Resources.ResourceWriteSuccess` to integration plane. Egress guard: any non-loopback/non-peer outbound connect ⇒ refused + telemetry (`R_missing_authority`).
- **Accept** topology test: token from identity plane accepted by data plane, token signed by foreign key refused 401; ARM PUT ⇒ Service Bus subscriber receives ResourceWriteSuccess; `tcpdump`/egress-guard counter shows 0 non-loopback connects over the suite.
- **Falsifier** any cross-plane call resolved in-process (no socket) or any non-loopback egress.
- **Anti-vacuity** disable issuer check → foreign-token test must fail.
- **Receipt** `azb-10-cross-plane.md`.

---

## E3 — Process Isolation & Noise Fences

### AZB-11 — Isolation court (start_supervised! + put_env guards)
- **Q** ELIMINATE · **Lane** isolation · **Deps** —
- **Scope** `scripts/isolation_court.py`, `justfile.d/25-leak-court.just` (add `isolation-court` recipe), offending `test/**/*_test.exs` (batched ≤12/ticket-slice)
- **Baseline (observed `21f58b0`)** `grep -rln "Application.put_env" test | wc -l` → `80` files (guarded vs unguarded not yet classified; court's first run produces the split).
- **Spec** Static court over `test/`: (a) every `GenServer.start_link`/`Agent.start_link`/`Task.start_link`/named singleton start in a test body must be `start_supervised!/1`; (b) every `Application.put_env` / `Application.delete_env` must have a paired restore in `on_exit` (or use the existing env-guard helper) in the same setup scope. Exemption only via inline `# isolation-court: exempt <reason>` with reason; exemptions counted in receipt. Runtime twin: after each async module, `Process.registered()` diff and `Application.get_all_env(:smalt)` diff vs baseline ⇒ fail with module name.
- **Accept** `just isolation-court` exit 0 on fixed tree; full suite green ×2 with runtime twin enabled.
- **Falsifier** env or registered-name diff observed after any module.
- **Anti-vacuity** fixture test with bare `Application.put_env` → court exit 1 naming file:line.
- **Receipt** `azb-11-isolation-court.md` (counts: sites found / fixed / exempt).

### AZB-12 — Absolute timing bounds → relative-ratio assertions
- **Q** REDUCE · **Lane** isolation · **Deps** —
- **Scope** test files carrying absolute ms latency asserts (inventory first), `test/support/ratio.ex` (helper)
- **Spec** Inventory: `rg -n 'assert .*(<|<=) *[0-9]+ *(#.*ms)?' test/ | rg -i 'ms|latency|elapsed|duration'` + `:timer.tc` comparisons. Replace each with `assert_ratio(subject_us, baseline_us, max: k)` where baseline is a same-run calibrated control op (median of 5), k recorded per site with justification. Correctness-bearing deadlines (protocol timeouts) stay absolute but move to injected clocks. Reuse `rewrite-drafts/fence10-ratio.md` design.
- **Accept** inventory count → 0 unconverted absolute bounds; converted tests green under `just burn-chaos` (8 hogs).
- **Falsifier** a converted test goes RED under 8-hog load with no product change.
- **Anti-vacuity** inject a 10× slowdown in the subject op → ratio assertion must fail.
- **Receipt** `azb-12-ratio-fences.md` (site table: file:line, old bound, k, baseline op).

---

## E4 — Burn Ring & Chaos

### AZB-13 — Boot burn ×50 per plane (Jidoka on orphan/zombie)
- **Q** CREATE · **Lane** burn · **Deps** AZB-02, AZB-03, AZB-09
- **Scope** `docker/burn/boot-burn.sh`, `docker/burn/container-burn.sh`
- **Spec** Per container: 50× {boot release with `SMALT_PLANES=<plane>` → readiness deadline-poll on plane's health route → probe (one canonical request per plane) → graceful stop (`bin/smalt stop`) → assert: no listener on plane ports (`ss -ltn`), no `beam.smp`/`epmd`/`erl_child_setup` remains, no `crash.log`/`SASL` crash report}. First violation ⇒ emit non-CLEAN row, exit non-zero immediately (line-stop; remaining cycles not run, recorded as `NOT_RUN`).
- **Accept** `just burn-boot --planes all,control,data,integration,identity --cycles 50` exit 0; `validate_burn.py --gate` exit 0 over 5×50×{boot,probe,teardown} cells.
- **Falsifier** any orphan listener or zombie BEAM across 250 cycles.
- **Anti-vacuity** spawn a detached `nc -l 9443` in teardown hook → cycle must stop with `ORPHAN_LISTENER`.
- **Receipt** `azb-13-boot-burn.md` + `burn/boot-<run>.jsonl`.

### AZB-14 — SIGKILL storm + DETS needs_repair + typed vocabulary
- **Q** RAISE · **Lane** burn · **Deps** AZB-13, AZB-06
- **Scope** `docker/burn/chaos-kill.sh`, `lib/smalt/store/dets_mirror.ex` (repair path only if defect found), `test/azsim/dets_recovery_test.exs`
- **Spec** Under write load on data plane: `kill -9` the VM at randomized-but-seeded offsets (seed in row), 50 cycles. On reboot: DETS opened with `repair: true`, `needs_repair` path exercised (assert via log/telemetry `[:smalt, :store, :dets_repaired]`), every acknowledged write (client-side ledger) present, zero unacknowledged phantom writes. Forced corruption variant: truncate DETS file tail / flip header byte ⇒ typed boot outcome (repair succeeds, or plane refuses with `:store_corrupt` and other planes keep serving) — never an untyped crash loop. During graphlaw/WasmEngine kill mid-request ⇒ caller receives `:engine_unavailable` (HTTP 503 typed body).
- **Accept** `just burn-chaos-kill --cycles 50 --seed $SEED` exit 0; ledger diff = 0 lost acks; corruption variants all typed.
- **Falsifier** lost acknowledged write; untyped 500; supervisor max-restart escalation to app stop.
- **Anti-vacuity** open DETS with `repair: false` → corruption cycle must emit `DETS_UNREPAIRED`.
- **Receipt** `azb-14-sigkill-dets.md` (seeds, repair counts, ledger diff).

### AZB-15 — Plane subtree DR kills (enterprise disaster scenarios)
- **Q** RAISE · **Lane** burn · **Deps** AZB-09, AZB-10
- **Scope** `test/azsim/dr_scenarios_test.exs`, `lib/smalt/plane/*_supervisor.ex` (only if defect)
- **Spec** Scenarios via `Supervisor.terminate_child/restart_child` on a live all-planes node, each with a recovery metric (time-to-first-200 measured in reductions/messages, reported not asserted absolutely):
  1. Cosmos partition split: kill data subtree mid-query stream ⇒ client sees `410 Gone / substatus 1002` (PartitionKeyRangeGone) or retryable 503, then success on retry.
  2. Service Bus outage: kill integration subtree ⇒ AMQP clients get `amqp:connection:forced`, reconnect, no message loss for settled-after-reconnect peeks.
  3. STS outage: kill identity subtree ⇒ cached-valid tokens still accepted by data/control until TTL; new token mint ⇒ 503 typed.
  4. ARM outage: kill control subtree ⇒ data plane unaffected (200s continue).
- **Accept** all 4 scenarios green ×10 iterations; zero cross-plane failures outside the declared blast radius.
- **Falsifier** a request on an unkilled plane fails during any scenario.
- **Anti-vacuity** wire data plane to call identity in-process (shared process) → scenario 3 blast-radius assertion must fail.
- **Receipt** `azb-15-dr-subtrees.md`.

### AZB-16 — AMQP saturation (≥4096 queues) + atom-flood guard
- **Q** RAISE · **Lane** burn · **Deps** AZB-07
- **Scope** `test/azsim/amqp_saturation_test.exs` (`@tag :stress`), `docker/burn/container-burn.sh`
- **Spec** Create 4096 queues (plus 8192 variant), 1 sender + 1 receiver link each, 10 msgs/queue. Assert: atom table growth bounded (`:erlang.system_info(:atom_count)` delta < 64 — i22 class), process count returns to baseline ±1% after link teardown, zero `:closed` logger flood lines, DLQ correct for poisoned messages, memory returns within 10% of baseline after `:erlang.garbage_collect` sweep.
- **Accept** stress test green ×3 inside container under `cpus: 2`.
- **Falsifier** atom delta unbounded in queue count; process leak after teardown.
- **Anti-vacuity** `String.to_atom(queue_name)` in a link path → atom assertion must fail.
- **Receipt** `azb-16-amqp-saturation.md`.

### AZB-17 — Parallel plane matrix (N containers × 4 planes)
- **Q** CREATE · **Lane** burn · **Deps** AZB-14, AZB-15, AZB-16
- **Scope** `docker/burn/parallel-matrix.sh`, `docker/burn/compose.burn.yml` (generated matrix)
- **Spec** N ∈ {4, 8} replicas of the 4-plane topology (one netns per plane per replica, replicas on separate compose networks ⇒ cross-tenant isolation). Each replica runs offline suite + wire tier + compliance corpus + its plane's chaos stage. Tenant canary: each replica writes a replica-unique marker; assert no replica ever reads another's marker.
- **Accept** `just burn-matrix --replicas 8` exit 0; `validate_burn.py --gate` over 8×4 cells exit 0; canary cross-reads = 0.
- **Falsifier** any cross-replica read or any non-CLEAN cell.
- **Anti-vacuity** attach two replicas to one network with shared DETS volume → canary must fire.
- **Receipt** `azb-17-parallel-matrix.md`.

### AZB-18 — cgroup-constrained soak
- **Q** RAISE · **Lane** burn · **Deps** AZB-17
- **Scope** `docker/burn/soak.sh`, `compose.burn.yml` (`cpus`, `mem_limit`, `pids_limit`)
- **Spec** Matrix under `cpus: 0.5 / 1 / 2`, `mem_limit: 1g`, `pids_limit: 512`, plus host 8-hog chaos. Failures classify against `docs/jira/v26.10.17/FLAKE_LEDGER.md` classes; unclassified failure ⇒ new ledger row + RED.
- **Accept** 3 rounds × 3 quota tiers green; 0 unclassified rows.
- **Falsifier** any failure at `cpus: 0.5` not attributable to a ledgered class.
- **Anti-vacuity** reintroduce a 250ms absolute bound (pre-AZB-12 shape) → must go RED at `cpus: 0.5`.
- **Receipt** `azb-18-cgroup-soak.md`.

---

## E5 — Pipeline, Interop, Gates

### AZB-19 — Port-free stage overlap scheduling
- **Q** REDUCE · **Lane** pipeline · **Deps** AZB-13
- **Scope** `justfile.d/30-burn.just`, `justfile.d/07-court-x2.just` (schedule only)
- **Spec** Stages declare resources (`ports`, `build_root`, `dets_dir`); a scheduler (`just` deps + `MIX_BUILD_ROOT=_build-burn-<stage>` per stage) runs stages with disjoint resource sets in parallel: compile-once → {offline suite ∥ corpus ∥ static courts} → {wire tier (ephemeral ports) ∥ container matrix (netns)}. Baseline wall-clock measured on same host at `21f58b0` (3 runs, median).
- **Accept** median wall-clock reduction ≥ 40% vs baseline over 3 runs; verdicts identical to serial run.
- **Falsifier** any verdict differs between serial and overlapped schedules.
- **Anti-vacuity** give two overlapped stages the same `MIX_BUILD_ROOT` → scheduler must refuse (`RESOURCE_CONFLICT`).
- **Receipt** `azb-19-overlap.md` (baseline vs overlapped timings).

### AZB-20 — Unmodified Microsoft SDK interop per plane
- **Q** RAISE · **Lane** interop · **Deps** AZB-10
- **Scope** `justfile.d/14-sdk-matrix.just` (add `azsim-sdk`), `workspace/` SDK lanes
- **Spec** Against plane-per-container topology, unmodified official SDKs: control ⇒ `terraform` azurerm plan/apply/destroy + `azure-mgmt-resource`; data ⇒ `azure-cosmos`, `azure-storage-blob` (conditional + range); integration ⇒ `azure-servicebus` (send/receive/DLQ/session), Event Grid publisher; identity ⇒ `azure-keyvault-secrets`, `azure-keyvault-keys`, `azure-identity` against STS. Assert headers `x-ms-request-id`, `x-ms-version`, `ETag` on every response captured by a recording proxy.
- **Accept** `just azsim-sdk` exit 0; header audit 100% coverage.
- **Falsifier** any SDK requires a patch/monkeypatch/env hack beyond endpoint + CA trust.
- **Anti-vacuity** strip `x-ms-request-id` in one router → header audit must fail.
- **Receipt** `azb-20-sdk-interop.md` (SDK versions, pass table).

### AZB-21 — Zero-sleep gate (lib + test + burn scripts)
- **Q** ELIMINATE · **Lane** gates · **Deps** —
- **Scope** `justfile.d/29-sleep.just`, gate script
- **Baseline (observed `21f58b0`)** `grep -rn "Process.sleep" lib test | wc -l` → `100` raw hits (unclassified: includes comments/docstrings/NO-SLEEP fence fixtures). First step: classify each hit {code, comment, fixture-of-gate}; only `code` counts toward G1.
- **Spec** Extend existing sleep gate to cover `docker/burn/*.sh` (`sleep [0-9]`), `test/support/`, and `:timer.sleep`/`receive after N ->` used as delay (not as deadline with a matched message). Allowlist only via typed classification file with reason.
- **Accept** `just sleep-gate` exit 0 on tree; count = 0 unclassified.
- **Falsifier** a delay primitive present and not flagged.
- **Anti-vacuity** seed `Process.sleep(10)` in a test and `sleep 1` in a burn script → gate exit 1 naming both.
- **Receipt** `azb-21-zero-sleep.md`.

### AZB-22 — Burn ring: 50-cycle all-green
- **Q** CREATE · **Lane** burn (coordinator) · **Deps** AZB-11, AZB-12, AZB-18, AZB-19, AZB-20, AZB-21
- **Scope** `justfile.d/30-burn.just` (`burn-ring` recipe), `docs/jira/v26.10.18/burn/`
- **Spec** `burn-ring` = boot burn ×50 → chaos ×50 → parallel matrix (N=8) → cgroup soak, all on one image digest bound to one subject SHA. Emits run summary receipt (5 fields: identity=SHA+digest, authority=lane lease, consequence=tracked JSONL path, replay=exact command+seed, standing derived by validator).
- **Accept** `just burn-ring` exit 0; `validate_burn.py --gate` exit 0; summary passes `~/.zcode/dfcm/validate_receipt.py`.
- **Falsifier** any non-CLEAN row, missing cell, or SHA/digest mismatch between rows.
- **Anti-vacuity** commit after ring start → validator must refuse (`R_missing_identity`, subject moved).
- **Receipt** `azb-22-burn-ring.md`.

### AZB-23 — court-x2 on frozen quiescent tree
- **Q** CREATE · **Lane** freeze (I20 analogue) · **Deps** AZB-22
- **Scope** `justfile.d/07-court-x2.just`, `justfile.d/24-quiesce.just`
- **Spec** Preconditions computed, not asserted: `git status --porcelain` empty, HEAD == AZB-22 subject SHA, `just quiesce` reports 0 foreign BEAMs/listeners, AZB-22 receipt present for this SHA. Then full offline suite + wire tier + compliance corpus, twice consecutively. RED ⇒ typed (`broken_term`), FLAKE_LEDGER row, no rerun without new hypothesis.
- **Accept** judge log shows run1 GREEN, run2 GREEN, same SHA.
- **Falsifier** precondition unmet yet court proceeds.
- **Anti-vacuity** dirty one file → court refuses before run1.
- **Receipt** `rNNN-court-x2-azsim-two-green.md` (fresh name; never reuse prior window names).

### AZB-24 — Release receipt, standing, and retirement
- **Q** CREATE · **Lane** freeze · **Deps** AZB-23
- **Scope** `mix.exs` `@version` → `26.10.18`, `workspace/package.json`, `CHANGELOG.md`, `docs/jira/v26.10.18/RECEIPTS.md`, `NEXT_WINDOW.md`, `~/.zcode/dfcm/composition-space.ttl` (burn-ring primitive standing)
- **Spec** Version bump strictly after AZB-23. `semanticEpoch` regenerated via projection (not hand-edited). Retire: burn-ring + isolation court + ratio helper recorded as rule/verifier so future windows invoke `just burn-ring` instead of re-deriving. Ticket standing table regenerated from receipts (`receipt_index.py`), never typed by hand.
- **Accept** `just docs-dod-check` exit 0; `receipt_index.py` shows 24/24 tickets with receipts and derived standing; `project.py --check` exit 0.
- **Falsifier** any ticket standing present without a receipt bound to the release SHA.
- **Anti-vacuity** delete one receipt → index must show that ticket UNKNOWN and docs-dod-check exit 1.
- **Receipt** `azb-24-release.md`.

---

## Lane partition (one writer per file per wave)

| Lane | Tickets | Exclusive files |
|---|---|---|
| foundry | 01, 02, 03 | `docker/Dockerfile`, `docker/burn/compose.burn.yml`, `scripts/validate_burn.py` |
| planes | 04–10 | `config/**`, `lib/smalt/application.ex`, `lib/smalt/plane/**`, `test/azsim/{*_plane,topology,plane_supervision}_test.exs` |
| isolation | 11, 12 | `scripts/isolation_court.py`, `test/support/ratio.ex`, touched `test/**` sites |
| burn | 13–18, 22 | `docker/burn/*.sh`, `test/azsim/{dets_recovery,dr_scenarios,amqp_saturation}_test.exs` |
| pipeline | 19 | `justfile.d/30-burn.just` (schedule section) |
| interop | 20 | `justfile.d/14-sdk-matrix.just`, `workspace/` |
| gates | 21 | `justfile.d/29-sleep.just` |
| freeze | 23, 24 | `justfile.d/07-court-x2.just`, `mix.exs`, `CHANGELOG.md`, `workspace/package.json` |

Seams: `application.ex` is planes-lane exclusive this wave; `30-burn.just` split by section (burn recipes vs schedule) — conflicts resolved in `RESOLUTIONS.md`.
