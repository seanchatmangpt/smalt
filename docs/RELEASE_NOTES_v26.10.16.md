# Release Notes — smalt 26.10.16

Second release of smalt: the v26.10.14 substrate (local Azure drop-in on the
BEAM — ARM control plane `:9443`, TLS twin `:9444`, data plane `:8443`,
AMQP Service Bus `:5672`, Event Hubs `:5673`, MCP `:9545`, loopback only)
advanced by a full repair-and-hardening wave. The surface inventory is
unchanged from v26.10.14; this window's work is correctness and parity:
128 receipt files landed in `docs/jira/v26.10.16/receipts/`, the SDK
parity register reached full mechanical coverage, and eight divergence rows
closed. Standing for this document: **BUILD_BROKEN** — court-x2 verdict
`COURT_X2_RC=1` (run-30, 2026-10-17; run-29's driver was killed mid
run 2 and never produced a verdict): both fresh `just court` runs exited 2
at `test-offline` with `1 doctest, 7 properties, 2435 tests, 1 failure`
each, on DIFFERENT tests — the shifting-failure/flake class
(`EventGridTopicsArmTest:302` vs `Amqp.QueueStoreTest:721`; run-12's
witnessed family was `Lens6StructuralTest:463`/`Lens7FieldPolicyTest:545`).
Typed residual: the `.metadata_never_index` Metadata-indexer mitigation
(placed at the repo root 2026-10-17 01:14 after the Spotlight-class
indexer was found saturating the host during wrap re-courts) remains
**UNMEASURED** — no post-marker court run has completed green on a quiet
host. **32 completed invocations, 0 two-green** (terminal run-32
supersedes run-30 here: run 32.1 completed TYPED — `2457 tests, 7
failures`, drift-fence class on the W2-late surface that landed as
`b6a8b7e` — run 32.2 aborted at `just doctor` port-in-use; see
`docs/jira/v26.10.16/WRAP_LEDGER.md` runs 30-32). See
`docs/jira/v26.10.16/FINAL.md` court-x2 line and the runs 22-29
post-mortem in `docs/jira/v26.10.16/WRAP_LEDGER.md`. Publish standing
(covers hex + tarball): **TYPED-BLOCKED** per
`docs/jira/v26.10.16/PUBLISH_RECORD.md` — "PUBLISH-READY: NO —
TYPED-BLOCKED" (final); the remaining refusal-class blocker is **B1**,
the non-optional `ex4pm` path dependency refusing `hex.build`
(typed `HEX_BUILD_REFUSED`; B4 closed at T5).

## What changed

- **SDK parity register at full coverage** — `KNOWN_DIVERGENCES.md` spans
  **94 rows (KD-01..KD-94 — 38 CLOSED / 56 OPEN as of the 2026-10-17
  lane-I14 recount**; per-row escaped-pipe-aware split: 14 CLOSED-WITH-RECEIPT +
  17 CLOSED-SIMULATED + 5 CLOSED-with-receipt + 2 plain CLOSED (KD-52, KD-63);
  the register was being flipped concurrently by the kd-registrar lane during
  the recount — re-derive at use time per
  `docs/jira/v26.10.17/COUNTERS.md`; supersedes the 28/66 figure minted
  before the KD-89/KD-94/KD-63/KD-80/81/82/87/91 flips)** in the canonical table
  (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`; the v26.10.16 window keeps a
  pointer file). KD-91/92 were minted OPEN from the c11 typed findings
  (fixes landed, witness-pending); KD-93 was minted OPEN by the lane X5
  registrar (cosmos query-feed scope/freshness, evidence
  `receipts/bench-c11-tf-loop.md`); KD-88/89/90 were minted after this
  window's original audit; KD-94 was minted by the J16/659 repair lane
  (cosmos AAD Authorization shape; fix landed + fenced, wire witness
  pending). **Eight rows closed this window**, all flipped via
  `scripts/kd_flip.py --apply` gated on a witness receipt postdating the
  shim mtime:
  - **KD-45** (SB management ATOM+XML: `createQueue` PUT now returns a
    well-framed HTTP/1.x ATOM+XML response; census probes proceed past the
    HPE_INVALID_CONSTANT parse error) — witness
    `docs/jira/v26.10.16/receipts/r178e-census-replay-repair.md`.
  - **KD-46** (SB deferred redelivery now carries `deliveryCount`) —
    witness `docs/jira/v26.10.16/receipts/r200f-kd46-mgmt-surface.md`.
  - **KD-53** (EH multi-event batch: createBatch with N>1 delivers all N
    inner messages; previously events 2..N were silently dropped) —
    witness `docs/jira/v26.10.14/receipts/2026-10-15-kd53-eh-batch-witness.md` (lives in the
    v26.10.14 window — the repair bridged windows).
  - **KD-54** (ARM `GET /subscriptions/{sub}/resources` route landed;
    `client.resources.list()` → 200 value[]) — witness
    `docs/jira/v26.10.16/receipts/r119-r123-arm-list-store-reseed.md`.
  - **KD-68** (EH selector-filter / `eventPosition` decoded and applied in
    `handle_attach/3`; falsifier re-ran green post-shim) — witness
    `docs/jira/v26.10.16/receipts/r200d-kd68-selector-impl.md`.
  - **KD-70** (EH delivery_annotations: `partitionContext.
    lastEnqueuedEventProperties` exposes offset/sequenceNumber/enqueuedOn
    with `trackLastEnqueuedEventProperties: true`) — witness
    `docs/jira/v26.10.16/receipts/r200a-kd70-delivery-annotations.md`.
  - **KD-71** (EH `x-opt-offset` / `x-opt-enqueued-time` /
    `x-opt-partition-key` stamped per delivery; real-SDK falsifier 4/4) —
    witness `docs/jira/v26.10.16/receipts/r200b-kd71-xopt-props.md`.
  - **KD-76** (pk-routed sends now deliverable via partition-scoped
    subscriptions on the real SDK receive path) — witness
    `docs/jira/v26.10.16/receipts/r200h-kd76-pk-witness-repair.md`.
- **KD-77 minted OPEN** (kd-registrar audit 2026-10-16): AMQP delivery-tag
  encoding on the settle path — lock-tokens surface to pyamqp as UUID
  objects instead of 16 raw bytes (`object of type 'UUID' has no len()` on
  batch-delete/DLQ settle). Previously misattributed to KD-49 ("delivery-tag
  half" skip banners); the split is now a registered row with falsifier:
  batch-delete/DLQ settle via azure-servicebus completes without UUID
  TypeError.
- **Repair highlights** (receipts in `docs/jira/v26.10.16/receipts/`):
  blob WORM immutability + CAS parity batch
  ([r188-r196-r197-worm-settle-batch.md](jira/v26.10.16/receipts/r188-r196-r197-worm-settle-batch.md));
  lock ABA telemetry read guard
  ([r144-lock-aba-telemetry-read-guard.md](jira/v26.10.16/receipts/r144-lock-aba-telemetry-read-guard.md));
  egress comp/envelope/sentinel quote-parse fences
  ([r124-r126-egress-comp-envelope-sentinel-quote-parse.md](jira/v26.10.16/receipts/r124-r126-egress-comp-envelope-sentinel-quote-parse.md));
  ETS hygiene batch (deleted-table telemetry GenServer,
  [r116-telemetry-genserver-deleted-table.md](jira/v26.10.16/receipts/r116-telemetry-genserver-deleted-table.md)
  lineage); Cosmos patch admission gates
  ([r10-cosmos-patch-admission-gates.md](jira/v26.10.16/receipts/r10-cosmos-patch-admission-gates.md));
  Cosmos ETag final-body court
  ([r134-cosmos-etag-final-body.md](jira/v26.10.16/receipts/r134-cosmos-etag-final-body.md)).
- **New courts this window**: receipt-index drift gate
  ([r08](jira/v26.10.16/receipts/r08-receipt-index-drift-gate.md)),
  receipt standing scan glob ([r09](jira/v26.10.16/receipts/r09-receipt-standing-scan-glob.md)),
  error-codes regen + drift fence
  ([r11](jira/v26.10.16/receipts/r11-error-codes-regen.md)),
  KV court CA anchoring
  ([r152](jira/v26.10.16/receipts/r152-kv-court-ca-anchoring.md)),
  immutability/CAS parity court
  ([r153](jira/v26.10.16/receipts/r153-immutability-cas-parity.md)),
  wire fences W1–W3
  ([r155](jira/v26.10.16/receipts/r155-wire-fences-w1-w3.md)),
  API-version + scheduled type-guard gates
  ([r143](jira/v26.10.16/receipts/r143-apiversion-gates.md),
  [r142](jira/v26.10.16/receipts/r142-scheduled-type-guard.md)),
  court hardening batch
  ([r187b-r190](jira/v26.10.16/receipts/r187b-r190-court-hardening-batch.md)).
  Full inventory: `docs/jira/v26.10.16/receipts/INDEX.md` (regenerated
  2026-10-16: 152 receipt files + 34 sdk-results = 186 total receipt files
  in this window's ledger; 17 SUSPECT output-less flags across all
  windows, of which this window contributes spc-bands.md — flagged is the
  standard for scratch-class receipts, not an insult).
- **New capabilities this window** (each with its standing, per on-disk
  receipts):
  - **Affidavit WASM integration** — wasmex-mounted fail-closed engine
    (`lib/smalt/affidavit/wasm_engine.ex`, sha256-sidecar authority pin),
    affidavit seal module, trust_profile witness contract with the
    `:PQC_NOT_PROVISIONED` typed refusal retained as fail-closed fallback.
    Standing: **PARTIAL_ALIVE** — the PQC close of KD-89 stays pending;
    no post-quantum claims made
    ([cap-affidavit-wasm.md](jira/v26.10.16/receipts/cap-affidavit-wasm.md)).
  - **Affidavit ingestion functor seal sideband** — resource PUT and
    RG-delete cascade admit stored-record bytes through the engine; the
    seal is a sideband (a dead engine never changes the HTTP outcome) and
    witnesses live in ETS, never in wire records. Standing: **PASS**
    ([cap-ingestion-functor.md](jira/v26.10.16/receipts/cap-ingestion-functor.md)).
  - **FinOps avoided-spend calculator** — pure deterministic TS original +
    1:1 Elixir port with an honest `pqc_status` field; region multipliers
    documented as a port extension. Standing: **PASS**
    ([cap-finops-calculator.md](jira/v26.10.16/receipts/cap-finops-calculator.md)).
  - **Policy/RBAC engine** (`lib/smalt/policy.ex`) — policy
    definitions/assignments, `deny` (typed 400 PolicyViolation) and
    `audit` effects on the generic PUT path, scope-prefix enforcement,
    built-in roles served deterministically
    ([r133-policy-row-cas.md](jira/v26.10.16/receipts/r133-policy-row-cas.md)).
  - **App Config `/kv` CRUD + CAS**, **monitor metrics + azapi emit**,
    **Event Grid topics with inputSchema-gated EG1**, **EH consumer-group
    enumeration with `$default` synthesis**, **blob snapshot/metadata
    surface**, **cosmos container throughput + NoSQL SQL query engine**
    (`lib/smalt/cosmos_sql.ex`), **KV secret rotate** (ARM `POST
    .../rotate` with cross-plane egress read-back), **SB/EH child-resource
    api-version lattice `2024-01-01`**, **trust shim v2** (leaf-exact
    certificate pinning), **Diátaxis docs restructure**, **ex4pm OCEL
    doctor/court emitters**, **docker ex4pm build context**.


### Enclave (in flight)

Approved plan ARD-PRD-SMALT-26.10.16-V1: a zero-HCL azurerm 4.54.0 enclave
driven entirely against the local substrate. Status is mixed — the tooling
and register seams are LANDED, the end-to-end goal is not. Each item below
is marked per actual disk state (checked 2026-10-16); IN-FLIGHT items have
no on-disk referent and are named only as approved-plan scope.

**LANDED**

- **Secrets data plane** — `/secrets` routes on the 8443 egress plane
  (list/PUT/GET/DELETE) backed by the `:smalt_vault_secrets` store
  (`lib/smalt/egress_router.ex:732-810`); pinned by
  `test/egress_secrets_test.exs` (9 tests).
- **Vaults/secrets + Cosmos sql child admissions** — the registry admits
  **41 resource types**, including `Microsoft.KeyVault/vaults/secrets`
  and `Microsoft.DocumentDB/databaseAccounts/sqlDatabases` /
  `sqlContainers` (`lib/smalt/registry.ex`); ARM child routes at
  `lib/smalt/arm_gateway/router.ex:961-1025` (sql wrapper) and
  `:1876-1928` (vaults/secrets); pinned by
  `test/kv_secrets_children_test.exs`.
- **Zero-drift defaults + sku aliasing** — `Defaults.apply/2` deep-merge
  wired into the storefront PUT path with `maybe_put_sku` storage/cosmos
  sku+kind aliasing (`lib/smalt/arm_gateway/defaults.ex`,
  `lib/smalt/arm_gateway/router.ex:768-814`); pinned by
  `test/defaults_test.exs` (9 tests; RETIRED@64f6099) +
  `test/zero_drift_serialization_test.exs` (honest caveat: 3 of its
  cases red at check time, 2026-10-16, mid-wave).
- **Cascade teardown completion** — resource-group delete cascades
  children by STORE KEY, never by the record's own `id` member
  (`lib/smalt/arm_gateway/router.ex:611-636`); the data-plane half
  (`BlobStorage.drop_account_data/1`, `blob_storage.ex:31`, wired at
  `router.ex:674,2469`) and the top-level storage-account DELETE route
  (`router.ex:2444`) are on disk.
- **api-version monotonic admission (KD-78)** — `check_version/3`
  accepts any version <= latest for the admitted type (`version_lte?/2`);
  only newer/malformed versions get a typed `InvalidApiVersionParameter`
  naming latest (`lib/smalt/arm_gateway/router.ex:1273-1300`); pinned by
  `test/apiversion_matrix_test.exs` (17 tests).
- **e1 enclave-loop bench lane** — `just enclave-loop`
  (`justfile.d/21-enclave.just`) drives `scripts/tf_enclave_loop.sh`
  (lane-private substrate, loud-skip exit 3); result jsonl at
  `docs/jira/v26.10.16/bench/e1-enclave-loop.jsonl`.
- **NFR gates** — `scripts/nfr3_rss_gate.py` + `scripts/stress/beam_rss.py`
  (delta-RSS) + `test/smalt_ets_baseline_identity_test.exs`.
- **KD details[] corpus rows** — error-corpus fence rows pinning the ARM
  error envelope in `test/arm_error_corpus_test.exs` (21 tests).

- **Terraform parity fixture** — `test/terraform_fixture/` (RETIRED@64f6099 — tf fixture tree deleted in the clean-room reset; successor: the tf smoke in the court pipeline):
  `versions.tf` pins `azurerm` to exactly `= 4.54.0` (`azapi = 2.4.0`),
  `main.tf` plans one resource group (`rg-smalt-fixture`), one key vault
  (`kv-smalt-fixture`), and one storage account (`smaltfixturestore`),
  `outputs.tf` exports ids (connection string deliberately NOT exported).
  Committed `plan.tfplan` on disk. Gates: `just tf-plan-smoke` via
  `scripts/tf_smoke.sh` / `scripts/tf_plan_check.sh`.
- **Darwin trust flow** — `scripts/tf_trust_setup.sh`
  (status/trust/retrust/untrust; fingerprint gate catches a dead re-minted
  CA still trusted in the login keychain and routes to retrust; a dismissed
  SecurityAgent approval dialog is a loud remediation, never a silent pass)
  + `scripts/tf_trust_check.sh`.
- **pf/hosts reachability** — `scripts/pf_redirect.sh` (packet-filter
  redirect) and `scripts/hosts_alias.sh` (hosts-file aliasing).
- **Offline provider mirror (script + material)** —
  `scripts/tf_provider_mirror.sh` downloads the azurerm binaries into
  `test/terraform_fixture/provider-mirror/` (gitignored; tree RETIRED@64f6099) and writes
  `provider-mirror.rc` pointing `TF_CLI_CONFIG_FILE` at the filesystem
  mirror so `tf_smoke.sh`/`tf_plan_check.sh` run fully offline.
  Idempotent; the mirror material
  (`provider-mirror/registry.terraform.io/` + `provider-mirror.rc`) is
  on disk on this host.

**IN-FLIGHT (no on-disk referent yet)**

- **Zero-HCL goal end-to-end** — plan-parse is green on all six
  terraform provider legs (rg, storage, cosmos, keyvault, eventhub,
  servicebus; `docs/jira/v26.10.16/sdk-results/tf-plan.md`), but apply
  still fails at the existence-check GET: azurerm 4.54.0 requests
  api-versions newer than each type's registry latest, and the monotonic
  gate (KD-78) admits only versions <= latest. Until the registry
  carries azurerm 4.x-era per-type maxima (or serves them), apply stays
  typed-divergent (`WRAP_LEDGER.md` item 6). P1 blocker.
- **T5 clean-room lifecycle** — no on-disk referent yet
  (`scripts/tf_enclave_loop.sh` is T5-adjacent, not the T5 subject).

## Benchmarks snapshot (b7 — in-BEAM native store)

From `docs/jira/v26.10.16/BENCH_RESULTS.md` (generated by `just
bench-report`; machine-readable rows in `docs/jira/v26.10.16/bench/`).

| op | n | ops/sec |
|---|---|---|
| put | 120000 | 1,006,610 |
| get | 120000 | 1,694,796 |
| compare_and_swap | 120000 | 263,479 |
| concurrent_put_get_32p | 512000 | 11,945,034 |
| list_prefix_10k | 10000 | 1,539,172 |

SDK-vs-BEAM multiplier narrative lives in the per-lane receipts
(`docs/jira/v26.10.16/receipts/bench-*.md`), not restated here.

## Known parks (open, tracked in `docs/jira/v26.10.16/WRAP_LEDGER.md`)

- **KD-77** — AMQP delivery-tag UUID-vs-raw-bytes encode divergence on the
  pyamqp settle path (minted OPEN this window; falsifier in the register
  row).
- **Census-flake notes** — timing-sensitive census/pagination flakes parked
  with close conditions: perf flake
  `test/data_plane/blob_hardening_test.exs:~1523` (RETIRED@64f6099; environment-sensitive,
  not a product defect) and the census regression park
  ([r178e-census-regression-park.md](jira/v26.10.16/receipts/r178e-census-regression-park.md)).
- **QueueDescription gaps** — remaining Service Bus administration-surface
  gaps are typed in the KD register rows (see KD-45's sibling ATOM+XML
  rows); no silent omissions.
- Additional open parks carried in `WRAP_LEDGER.md`:
  ledger-lazy-create-default close-condition proposal, DetsMirror
  union-growth park.

## Upgrade notes

None — same surface inventory as v26.10.14; no config keys removed, no
breaking wire changes. Wire-compat pinions (SASL ANONYMOUS only, sasl
outcome descriptor `0x44`, 14-field attach with omitted locale fields,
.NET-GUID lock-token byte reordering, EH fixed partitions `["0","1"]`)
remain pinned and unchanged. Migration guidance stays in
`docs/MIGRATION_FROM_EMULATORS.md`.

## See Also

- `docs/jira/v26.10.16/WRAP_LEDGER.md` (open parks, close conditions)
- `docs/jira/v26.10.16/BENCH_RESULTS.md` (generated bench snapshot)
- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (canonical KD register)
- `docs/MIGRATION_FROM_EMULATORS.md` (migration guidance)
