# FINAL — smalt v26.10.20 (terminal)

Executive close-out compiled from on-disk receipts only (window:
`docs/jira/v26.10.20/`, canonical KD register: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`).
The prior wave-6 capability-campaign close-out that lived at this path is
preserved in git history; its headline facts (router split w6R, plane fence
w6bk, ~30 capability faces, 53 wave-6 receipts: 33 ALIVE / 20 PARTIAL_ALIVE)
remain cited in `RECEIPTS.md` and the receipts under `receipts/w6*.md`.

## 1. KD scoreboard

Ground truth is the canonical register table — 154 rows (KD-01..KD-156),
**15 OPEN / 136 CLOSED** (re-parsed from status cells this session; replay:
`grep -c '^| KD-' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` → 154). The
window pointer register is `docs/jira/v26.10.20/KNOWN_DIVERGENCES.md`.

**Closed this window (flips via `scripts/kd_flip.py --apply`, mtime-gated,
each row names its witness receipt in the status cell):**

- KD-114 (blob SharedKey admit + typed 401 tamper refusal;
  `receipts/kd114-sharedkey-close-witness.md`), KD-115, KD-116 (row premise
  was v6-API rot, not a wire gap — `receipts/kd115-116-diagnosis.md` §4,
  registrar 2026-10-21)
- KD-122..130 (blob CORS, queue content-type, namespace PUT, policy list,
  EC create/live-sign, lock sweep, partition-key, heartbeat-frame decode,
  container-already-exists — each with a `kd1xx-*-witness.md`)
- KD-127 (premise substantially rot, re-typed then closed), KD-134
  (requester-preference redelivery)
- KD-135/136/138 CLOSED-WITH-RECEIPT; KD-137/139 via
  `receipts/bkd-kd135-137-139-witness.md`; KD-140/141 via
  `receipts/fix1-kd140-kd141-witness.md`; KD-143 via
  `receipts/fix2-kd143-witness.md`
- KD-147..152 (cosmos doc system-props + quoted-GUID `_etag`, KV
  201-create / vault-host GUID id / future api-version 400, queue-plane
  RFC-4122 `x-ms-request-id`) — `receipts/fix3-kd147-152-witness.md`
  (court 5/5, live wire legs embedded)
- KD-131/132/133 (dev-key derivation ≥32-byte floor, CBS decode
  normalization, flow-field witness) — `receipts/fix4-amqp-witness.md`
- KD-155/156 (DELETE framing `http?/1` sniff misclassification + SHACL
  minCount default) — `receipts/kd156-sb-shape-fix.md`; dedicated KD-155
  witness `receipts/kd155-deletequeue-witness.md` (root cause pinned:
  the server answered an HTTP DELETE with an AMQP protocol frame)

**Minted this window: KD-153..KD-156** (X3 SB-lane defects + registrar
mirror; evidence `receipts/w32-api-conformance.md` and the kd-registrar
lane mint 2026-10-21). KD-153 (namespace PUT 202 vs 200/201 LRO face) and
KD-154 (child PUT location validation) are minted-OPEN; KD-155/156 closed
same window.

**Client-bound disposition: KD-88** — OPEN, client-bound. Server-side root
REFUTED (`receipts/kd88-attach-race-witness.md`: tables self-heal, attach
served correctly 40 ms cold); remaining scope is the client-side pump
pre-send stall + the KD-129 codec lead; falsifier re-typed to the client
surface.

## 2. smalt-migrate wave 1

Audit: `receipts/smalt-migrate-wave1-audit.md` (standing: per-lane
verdicts, all PASS). Command surface (Typer, mounted at `cli.py:75`):
`migrate scan | inject | rollback | generate` — scan consumes .tf + .bicep;
`pipeline`/`all` and `verify` are library-only (registration gap disclosed,
non-blocking). Tests: 37 passed across
`tests/test_migrate_{scan,manifest,inject,pipeline}.py` + 6 passed / 1 loud
typed skip in `test_migrate_verify.py` under `.venv-cli` (run the verify
lane under `.venv-cli`; azure-servicebus is an undeclared optional dep —
flagged to the M4 owner). NFRs witnessed: NFR-1 read-only inject (stdlib
imports only, `--dry-run` writes nothing), NFR-2 (50 resources < 30 s),
NFR-3 byte-deterministic manifests. e2e court: migrate e2e court 4/4 legs
per the window checkpoint (commit 4e1efe3 message; per-run displacement
rows in `receipts/cost4-migration-displacement.md` §3).

## 3. SCVD results

Terminal artifact: [scvd-wrap.md](scvd-wrap.md) (standing ALIVE, SUSPECT=0
over the testbed store). Tier ladder from [SCVD.md](SCVD.md) + `receipts/scvd-wave-summary.md`:

- **Tier 1**: PASS ×3 — 16-leg cosmos put/get, 63–66 ms wall, p99 ≤18 ms,
  2434–2540 ops/s, 0 errors.
- **Tier 2**: PASS at n=1024 only (456 ms wall vs 30 s budget, 2245 ops/s,
  0 errors); the three n=512 FAIL rows (512 errors) are recorded, not hidden.
- **Tier 3**: wall LOCATED at **L8192** — 0 errors through L4096
  (ramp-512/1024/2048/4096 all `unreached`, up to 16,384 ops at 975 ops/s);
  ramp-8192 fires 534 errors with `typed_fail_512: true` — a typed 512-class
  refusal, not a hang.
- **Tier 4 (tail invariance)**: **INVARIANCE-HOLDS under fence v2**
  (UPDATED 2026-10-21; superseded fence-v1's scalar 188.79 ratio as a
  fence-definition artifact — Little's-law queueing depth, not regression).
  Fence v2 = three conjunctive checks on min-of-3 best rounds (F1 throughput
  floor ≥0.5x c1, F2 depth envelope p99 ≤ 4×level×p99(c1), F3 zero errors);
  all levels pass. Legacy ratio preserved: `legacy_ratio_128_over_1: 124.79`.
  Host-beam 9-run tail-invariance HOLDS 7/7 rungs (actor ratio ≤1.13 max);
  in-browser scaling LINEAR through 1024 (`receipts/scvd-inbrowser-wall-witness.md`,
  3/3 OK — the "wasm wall nearer 256–512" prior REFUTED).
- **Tier 5 (chaos)**: 2000-conn TLS flood accepted-all; recovery PASS on
  run 2 (594 ms), run 1's CA-verification recovery failure recorded
  (`receipts/scvd-t5-conn-exhaustion-chaos.md`) — overload posture NOT
  production-equivalent, bounds the parity claim.
- **T18 EH ramp** (`tmp/bench/scvd-eh.jsonl`, lane `scvd-t18`): eventhubs
  send-c128, n=512, 2612.2 ops/s, 0 errors, standing PASS.
- **Soak (paired-min fence)**: `tmp/bench/scvd-soak2.jsonl` — 5 paired
  (30s load + idle-baseline) rounds, same 16-leg shape both phases;
  **paired-min drift −1.2% (fence <10%), total_errors 0, verdict PASS**,
  replacing T13's load-bound single-window fence.
- **Coverage matrix**: PRD phases 1–4 all LANDED + WITNESSED
  (scvd-wrap §4 table: S1 harness, reconciliation engine, in-browser sync
  stack, Y4 sync-fault verification 9/9 legs). Composed terminal witness:
  in-browser 31 legs — 16 OK / 15 typed SKIP / 0 FAIL
  (`popcorn_demo/receipts/20261021T075835Z-witness-all.md`). Wave lanes
  T1/T2/T3/T4/T5/T6/T12/T18 witnessed from jsonl; T7–T11, T13–T14
  UNWITNESSED (no jsonl on disk — nothing claimed).

## 4. Substrate fixes landed

- **EventGrid backpressure bounds** (T8 HIGHs): per-subscriber queue and
  `seen_ids` dedup set were UNBOUNDED (`receipts/scvd-backpressure-audit.md`);
  fixed with drop-oldest + dedup FIFO cap, non-vacuous
  (`test/internal/event_grid_backpressure_test.exs`; checkpoint commit 4e1efe3).
- **SHACL minCount** (KD-156): `GraphLaw.Validator.ShapeFile.add_property/3`
  defaulted `min_count` to 1, making `maxCount`-only props de-facto required
  — every child PUT without `location` 400'd. Default 1→0 with KD-COVERS
  marker; no shape relied on the implicit default; falsifier typed
  (`receipts/kd156-sb-shape-fix.md`, court 9/9 + 9 tests 0 failures).
- **KD-155 `http?/1` sniff**: 8-byte prefix dispatch misclassified HTTP
  DELETE as AMQP (server answered an AMQP protocol frame; node
  `HPE_INVALID_CONSTANT`). Method-word clause landed in `atom_bridge.ex`;
  layer 2: management DELETE now answers proper 204 No Content framing
  (`lib/smalt/messaging/amqp/atom_bridge.ex:250-259`, KD-COVERS: KD-155).
- **SBKEY boot key** (KD-131 family): a 12-byte historical
  `:sb_shared_key` could not meet SasVerifier's 32-byte floor → CBS 401s.
  Fix: deterministic dev_env derivation byte-identical to
  `scripts/dev_env.sh` + `validate_boot_key!/0` typed boot refusal for
  sub-floor keys, 3 Chicago tests, existing KD-131/132/133 triage suite
  still 7/7 (`receipts/sbkey-boot-config-fix.md`); substrate.sh default
  aligned (`receipts/fix4-amqp-witness.md`).
- **Cosmos capabilities**: doc bodies now carry exactly the spec set
  `_rid/_self/_ts/_etag` (KD-147), `_etag` is a quoted GUID (KD-148), CAS
  200/412 round-trip witnessed live (`receipts/fix3-kd147-152-witness.md`);
  fresh-db query-feed empty-result divergence (KD-93) remains OPEN
  (`receipts/kd-legacy-triage-20261021.md` probe transcript).

## 5. Value ledger

All figures COMPUTED-FROM-PUBLISHED-RATES (LIST; eastus; fetched Azure
Retail Prices cards). Labeled SCENARIO where fleet composition/volume is
assumed — never presented as measurement.

- **Scenario fleet $246/mo**: `receipts/cost4-migration-displacement.md` —
  50-resource fleet (25 Cosmos dev/test @ $5.84 floor + 10 SB Standard
  @ $9.81 + 10 storage accounts @ $0.21 + 5 KV) = **$246.25/mo =
  $2,955/yr** at list; the Cosmos anchor is corroborated by two measured
  displacement-ledger rows (`apex4-cas-1024`, `witness-all-31-legs`).
- **Floors-dominate finding**: the provisioned-floor ($5.84/730-hr-mo
  Cosmos, $9.81 SB base) dominates list-price billing; blob displacement is
  real but tiny ($0.0133/mo for the full measured 2,500-op APEX-2 profile) —
  `receipts/scvd-value-discovery.md` honest-boundary notes.
- **Egress tiers** (COST-3, `receipts/cost3-egress-quantification.md`):
  fetched Data Transfer Out internet meter `6bd64e8e` — tiers $0 (first
  100 GB) / $0.08 / $0.065 / $0.06 / $0.04 per GB, monthly-cumulative.
  Measured rehearsal volume is 4.3 MB → **measured egress displacement
  $0.00**; the 500 GB → $32.00/run, ~$1,664/team-yr weekly-cadence figures
  are labeled SCENARIO.

## 6. Open items (typed, carried forward)

1. **KD-155 204-shape fix witness**: the `atom_bridge.ex` 204 No Content
   DELETE framing fix + framing court (9/9) are landed, but the close
   condition — real-SDK `deleteQueue` succeeding end-to-end with a wire
   witness postdating the shim — is NOT yet witnessed; KD-155's flip rests
   on the framing court + `receipts/kd156-sb-shape-fix.md` re-witness.
2. **WS dirty-tree reds pending clean-tree re-derivation**:
   `receipts/ws-court-sweep-20261021.md` — ws-lint/ws-build/ws-court all
   failed on absent `workspace/node_modules` (recovered by `npm ci` in the
   addendum; re-derivation at a clean tree pending);
   `receipts/verify-all-sweep-20261021.md` — 8/13 stages red, every red
   attributed to in-flight shared-tree edits or environment (venv deps, ws
   scratch, distribution), standing SUSPECT, nothing proven a regression at
   HEAD `4e1efe3`.
3. **KD-131 witness in flight**: KD-131/132/133 carry CLOSED-SIMULATED via
   `receipts/fix4-amqp-witness.md`, but the shared-substrate CBS 401 face
   (boot-path 12-byte key) full-SDK re-witness on a rebooted substrate was
   still in flight at wrap; the SBKEY boot-config fix
   (`receipts/sbkey-boot-config-fix.md`, PARTIAL_ALIVE) was uncommitted at
   receipt time — coordinator owns the commit.
4. **MED findings in flight** (from `receipts/scvd-backpressure-audit.md`):
   AMQP listener DynamicSupervisor connection fan-in uncapped
   (listener.ex:127-142); implicit 5,000 ms GenServer.call timeouts on the
   Store CAS funnel, EventGrid, and EventHubs read path (BOUNDED by default,
   not typed/declared). Both typed MED, unfixed.
5. **Remaining OPEN KD rows (15)**: KD-04/10/13/14/23/75/79/86/88/90/92/93
   (pre-window opens + client-bound KD-88, per scvd-wrap §3b) + KD-142
   (systemic blob error ENVELOPE — Azure-XML StorageError contract not
   landed) + KD-153/154 (SB LRO/child-PUT shape, minted this window).
   KD-135 WORM posture: parity face landed
   (CLOSED-WITH-RECEIPT), posture re-verification lives in
   `receipts/w30-dual-mode-witness.md` / `receipts/w32-api-conformance.md`.

## Pointers

[RECEIPTS.md](RECEIPTS.md) · [KNOWN_DIVERGENCES.md](KNOWN_DIVERGENCES.md)
(pointer register) · [SCVD.md](SCVD.md) · [scvd-wrap.md](scvd-wrap.md) ·
[scvd-ledger.md](scvd-ledger.md) ·
[receipts/smalt-migrate-wave1-audit.md](receipts/smalt-migrate-wave1-audit.md) ·
[receipts/cost4-migration-displacement.md](receipts/cost4-migration-displacement.md) ·
[receipts/verify-all-sweep-20261021.md](receipts/verify-all-sweep-20261021.md)

---
*Addendum (BK-BMIR2, 2026-10-22): the `tmp/bench/scvd-eh.jsonl` and `tmp/bench/scvd-soak2.jsonl` evidence cited above now have byte-identical tracked mirrors at `docs/jira/v26.10.20/bench/` (paired-sha256-verified); provenance `docs/jira/v26.10.20/bench/PROVENANCE.md`.*
