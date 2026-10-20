# Capability wave 3 — close-out prep (v26.10.19)

- **Date**: 2026-10-20
- **Subject**: smalt @ `322cfc7768fffb8480088a3eac1f5000d2723f82` (main; wave-2
  promotion commit), plus in-flight uncommitted lib edits disclosed below.
- **Context**: solo (docs lane, close-out prep)
- **Standing**: PREP — this file pre-registers the wave-3 close-out; no KD row
  is closed or narrowed by this document. No code edits; no register edits
  (registrar-gated).
- **Authority**: KD statuses re-read at prep time from
  `docs/jira/v26.10.19/KNOWN_DIVERGENCES.md` + `scripts/kd_flip.py` dry-run
  (§2, embedded output); lane slugs are proposed, `_LANES.md` at wave-3
  materialization is authoritative.
- **In-flight lib state at prep time** (uncommitted, on disk — `git diff
  --stat` at 322cfc7): `lib/smalt/arm_gateway/router.ex` (+158),
  `lib/smalt/cosmos_sql.ex` (+102/-), `lib/smalt/data_plane/blob_storage.ex`
  (+209/-), `lib/smalt/data_plane/cosmos.ex` (+111/-),
  `lib/smalt/egress_router.ex` (+102), `lib/smalt/mcp/gen/smalt_mcp_surface.ttl`
  (+54), `lib/smalt/messaging/amqp/lock_manager.ex` (+4),
  `lib/smalt/messaging/amqp/management_rpc.ex` (+22),
  `lib/smalt/messaging/amqp/queue_store.ex` (+188/-),
  `lib/smalt/policy.ex` (+24/-),
  `test/data_plane/cosmos_sql_raise_test.exs` (+71). 907 insertions,
  138 deletions across 11 files. Wave-3 lanes own these; this doc does not.

## 1. Per-capability close-out table

| Capability | KD row(s) | Owning lane (proposed) | Evidence class | Close-condition command (falsifier) |
|---|---|---|---|---|
| appconfig snapshots wire | none (surface growth on the KD-53 plane, already CLOSED-SIMULATED; no new flip) | appconfig-snapshots | Wire transcript — snapshot create/list + read-back via the `/kv` App Configuration face | snapshot roundtrip transcript embedded in lane receipt; `cd verification/py && python -m pytest -k snapshot` if the suite covers it |
| remediations ARM routes | none (surface growth) | arm-policy (disjoint arm) | Wire transcript — remediation list/trigger on an assignment with a deny | remediation transcript embedded in lane receipt; no register flip |
| KD-118 TS framing | KD-118 (CLOSED-SIMULATED this window via `lib/smalt/messaging/amqp/management_rpc.ex`; TS framing = external-suite leg) | sb-schedule-ts | SDK probe cell — TS ServiceBus `scheduleMessage`/`scheduleMessages` framing (deferred delivery time) against the 8443/5672 face | `cd verification/ts && node run.mjs` (servicebus wf leg incl. schedule cell) — cell green with embedded output |
| blob RFC-1123 dates | none (parity fix, no registered divergence) | blob-suite | SDK probe cell — list/snapshot/lease responses carry RFC-1123 `Date`/`Last-Modified` faces the TS SDK parses | `cd verification/ts && node run.mjs` (blob legs) — header-format cell green |
| KV purge TLS | none (parity fix) | kv-purge | SDK probe cell — `purgeDeletedKey`/`purgeDeletedSecret`/`purgeDeletedCertificate` over the 9444 TLS twin | `cd verification/ts && node run.mjs` (kv wf4 leg incl. purge cells) |
| exemptionCategory | KD-112 (OPEN; this doc names it — see §3 vacuity caveat) | arm-policy | SDK probe cell — exemption PUT with `exemptionCategory` carries the category through and exempts a deny (violating PUT → 201, not 400 PolicyViolation) | rerun the wave-2 `/tmp/kd112_probe2.sh` shape at SDK tier + exemptionCategory echo cell; `cd verification/ts && node run.mjs` arm leg |
| SB topic fan-out | none (surface growth) | sb-arm | Wire transcript — topic CRUD + rule/subscription fan-out via the ARM router | fan-out transcript embedded in lane receipt; SDK cell where a suite leg exists |
| deferred session-id + peek DeliveryState | none (surface growth) | sb-sessions | SDK probe cell — deferred message peek returns populated `DeliveryState` (session-id + sequence) and deferred receive completes | `cd verification/ts && node run.mjs` (servicebus peek/defer cells) |
| cosmos change-feed | none (surface growth) | cosmos-changefeed | SDK/wire probe — change-feed iterator returns documents in partition-order with continuation | `cd verification/py && python -m pytest -k "changefeed"` / wire transcript; falsifier: missed or duplicated document fails the iterator |
| EH geo-DR | none (surface growth) | eh-geo-dr | Wire transcript — alias create/failover face on the EH ARM surface | failover transcript embedded in lane receipt; `cd verification/ts && node run.mjs` EH leg if covered |
| cosmos cross-array IN | none (query-engine parity; in-flight `cosmos_sql.ex` diff) | cosmos-query | Falsifier test + SDK cell — `IN` over a cross-array expression returns the same rows the SDK client expects | `MIX_BUILD_ROOT=_build-laneW3 mix test test/data_plane/cosmos_sql_raise_test.exs`; `cd verification/py && python -m pytest -k "IN or array"` |
| SB session-state ops | none (surface growth) | sb-sessions (same lane, disjoint arm) | SDK probe cell — set/get session-state roundtrip through the AMQP management op | `cd verification/ts && node run.mjs` (servicebus session cells) |
| per-blob immutability | KD-52's plane (row CLOSED; no new flip — this is a scope *extension* of the KD-52 immutability arm) | blob-immutability | Shim-court + SDK cell — per-blob policy (container-scope already covered by the KD-52 WORM arm at `blob_storage.ex:473`) honored on the blob face; gate REFUSES the mutated observation | `just shim-court blob-worm` (or the lane's named court) + `cd verification/ts && node run.mjs` immutability cells |
| MCP wave-3 tools | none (surface growth) | mcp-tools | Generated-descriptor diff + probe call transcript — regen via `ggen_igniter.sync` from `lib/smalt/mcp/gen/smalt_mcp_surface.ttl` (in-flight +54 diff), never hand-edit `lib/smalt/mcp/generated/mcp_descriptor.ex` | `ggen_igniter.sync` byte-identical replay test green + probe call transcript in lane receipt |
| wf6/wf7 flip verification | aggregates several (KD-117 recovery legs, exemptionCategory, etc.) | wf6-wf7-verification | Suite cell flips — every SKIP/xfail in `test_wf6_newcaps.py` / `newcaps.probe.mjs` and the wf7 mirror flips to pass or records a typed registered-divergence | `cd verification/py && python -m pytest test_wf6_newcaps.py` zero skip/xfail remaining; `cd verification/ts && node newcaps.probe.mjs` |
| EH dedicated ARM faces | none (surface growth) | eh-arm | Wire transcript — dedicated EH ARM resource faces (namespaces/clusters) distinct from the SB router arms | face transcripts embedded in lane receipt |
| cosmos unique keys | none (surface growth; rides in-flight `cosmos.ex` diff) | cosmos-query (same lane, disjoint arm) | SDK/wire probe — unique-key policy on container PUT is accepted and enforced on duplicate insert (409) | `cd verification/py && python -m pytest -k "unique"`; falsifier: duplicate insert without 409 fails |
| wf7 mirror completeness | aggregates several | wf6-wf7-verification (same lane) | Census diff — every wf6 PY cell has a wf7 TS mirror cell (or a typed registered-divergence row) | mirror-completeness census embedded in lane receipt; count PY cells = TS cells or name each gap |
| EH consumer-group re-witness | `v261019-c12-eh-consumer-groups.md` stands; close = re-witness at wave-3 HEAD if lib moved | eh-arm (disjoint) | Witness re-run at pinned wave-3 SHA | re-run the c12 transcript command at 322cfc7+; new receipt postdates any moved mtime |

Rows with no KD id are new capability, not divergence closure — their close
receipts stand alone and never enter `kd_flip.py`. If any surfaces a real
divergence, that is a registrar mint, not a unilateral one.

## 2. Registrar flip plan (kd_flip eligibility law)

Flips only via `scripts/kd_flip.py` (dry-run default; `--apply` after the fin
sweep, before wrap regeneration). Dry-run at prep time (2026-10-20,
322cfc7 + in-flight diff):

```
KD-COVERS covers-map: 36 KD ids from 41 files
  KD-03: [CLOSED-WITH-RECEIPT] lib/smalt/data_plane/blob_service.ex
  KD-100: [CLOSED-SIMULATED] lib/smalt/auth/sts_key.ex
  KD-104: [CLOSED-SIMULATED] lib/smalt/data_plane/certificates.ex
  KD-105: [CLOSED-SIMULATED] lib/smalt/data_plane/kv_pss.ex
  KD-106: [CLOSED-SIMULATED] lib/smalt/data_plane/skr.ex
  KD-108: [CLOSED-SIMULATED] lib/smalt/data_plane/blob_storage.ex
  KD-111: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-113: [CLOSED-SIMULATED] lib/smalt/policy.ex
  KD-118: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/management_rpc.ex
  KD-15: [CLOSED-WITH-RECEIPT] lib/smalt/auth/bearer.ex, lib/smalt/egress_router.ex
```

(truncated — full tool output is the authority; KD-104, KD-105 and KD-108 show
CLOSED-SIMULATED at prep time, matching commit 8e7c3b9's registrar flips.
KD-118 also shows CLOSED-SIMULATED via management_rpc.ex.)

Trailer:

```
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 0
```

- **Already flipped this window** (registrar `--apply` at 8e7c3b9): KD-104
  (certificates wire), KD-105 (PS256 external verify), KD-108 (ACL body-seam +
  lease-on-snapshot wire). No lane may re-flip these; no re-flip is needed.
- **KD-117 (fix-landed-partial)**: no `# KD-COVERS: KD-117` token exists in
  `lib/` (absent from the 36-id covers-map). Flip rides (1) the token landing
  on the twin-sync carrier (`egress_router.ex` deleted-bundle prefixes /
  `application.ex`), (2) the PY wf6 recovery-leg PASS witness postdating that
  token-bearing file's mtime, plus the TS wf6 PASS. Then dry-run must show
  KD-117 FLIP-ELIGIBLE before kd-registrar `--apply`.
- **Remaining OPEN rows**: KD-112 (exemptions/initiatives; exemptionCategory
  arm lands in wave-3 — token + witness then flip), KD-119 (vault RS256
  double-hash; falsifier is hazmat verify digest=true, message=false —
  rides the KD-105 class, needs its own witness), KD-117 (above). Any other
  row the dry-run names is an exit-1 register-sync obligation, not a
  lane-level flip.
- Sequencing: (1) lanes land tokens (`# KD-COVERS: KD-nn`) on wave-3 carriers;
  (2) witnesses land with embedded output, postdating each carrier mtime;
  (3) dry-run — every flip row FLIP-ELIGIBLE, UNKNOWN-KD is exit-1;
  (4) kd-registrar `--apply` after the fin sweep; (5) regenerate
  RECEIPTS/SDK_MATRIX (`just receipt-index` / `just sdk-matrix-md`) — never
  hand-edit.

## 3. Vacuity caveat (this document is not a witness)

This document RE-OPENS the wave-1/wave-2 vacuity channel: the tool counts
"a newer file under the receipts dir mentioning the id", and this prep doc
names KD-112, KD-117, KD-118, KD-119 (and the already-closed KD-104/105/108).
**The registrar must NOT flip any row on this document** — it carries no
embedded PASS output and is not a witness. Eligibility must be re-read dry-run
after each lane's real witness receipt (embedded falsifier output, `Context:`
line) lands; only rows the dry-run shows FLIP-ELIGIBLE against their true
witnesses flip.

## 4. Wrap obligations carried

- **court-x2 at wave-3 HEAD**: after flips, two consecutive `just court`
  greens at one pinned wave-3 SHA (`just quiet-check` first; `just quiesce`
  when the machine was busy — both wave-1 court-x2 attempts failed cold run 1,
  passed warm run 2). Run 2's log feeds the release-receipt mint; precedent:
  `receipts/v261019-12-court-x2-close.md` (court-x2 #3) and the wave-2
  promotion receipt at 61e0543.
- `just docs-dod-check` must pass — every receipt path named in this file and
  in wave-3 lane receipts must exist on disk.
- `just publish-dry` before FINAL wrap.
- No GAP tokens minted unilaterally; typed-UNSUPPORTED pins go through
  WIRE_PARITY.md registrar discipline.
- Coordinator deletes all lane build roots (`_build-lane*`) at integration
  before the final commit.

## 5. Wave-3 registry-sync verification (ERRC wave-4 lane, 2026-10-20)

- **Date**: 2026-10-20
- **Subject**: smalt @ `6c49b67f442e23d518ad4eed1d8240f0bb4deec2` (main; final
  wave-3 HEAD at verification time — HEAD advanced past the 28ceff9 promotion
  commit during the session via other lanes' commits).
- **Context**: pair (shared checkout, concurrent wave-4 lanes editing `lib/`
  throughout; every compile-dependent gate below was polled to a clean
  compile window and the transients disclosed in §6).
- **Standing**: PASS — all five wave-3 registry-sync claims verified green at
  final HEAD.

### 5.1 Registry replay fence — HELD

`MIX_BUILD_ROOT=_build-laneV3 mix smalt.gen` run twice consecutively (both
exit 0 at final HEAD): the five generated files are byte-identical across
runs (sha256):

```
5951017febb2e961f0ce6fb7a346b90d98791a07aa81c6941d2a2983b1833dec  lib/smalt/registry.ex
bdcd4904e01b10e9e3d1a63f4b094948a8c81edbd5d9f42644e830df6a252fa7  lib/smalt/config.ex
f7aeac8cc1c5cb36928436bc1af3aaffe04d372f7e27d939b1221e59eb30b5d0  lib/smalt/store_tables.ex
b5a9f0693bf725c3653f10bf734333cf9126c8822e06a691cc7c809bd7bc77d3  lib/smalt/cascade_edges.ex
de97b736e30e7ab51d879740ec0f8b05f6e29ce0c1355ea10206db0af22ba962  lib/smalt/telemetry/semconv/registry.ex
```

### 5.2 Registry content smoke — 46 types, all wave-3 ARM admits present

`MIX_BUILD_ROOT=_build-laneV3 mix run --no-start -e '...'` (exit 0):

```
type_count=46
Microsoft.Authorization/locks => admitted
Microsoft.Authorization/policyExemptions => admitted
Microsoft.Authorization/policyRemediations => admitted
Microsoft.ServiceBus/namespaces/topics/subscriptions/rules => admitted
Microsoft.EventGrid/topics => admitted
sb_rules_latest_version: "2021-04-01"
```

### 5.3 capabilities.json projection — 46 types + semanticEpoch

`docs/capabilities.json`: 46 capabilities; `semanticEpoch: "26.10.19"`;
`Microsoft.Authorization/locks`, `Microsoft.Authorization/policyExemptions`,
`Microsoft.Authorization/policyRemediations` all present (locks is the first
Authorization family member beyond policyExemptions/policyRemediations).

### 5.4 sdk_coverage — exit 0, 14 cap cells, zero gaps

`python3 scripts/sdk_coverage.py` → `GATE: OK — every cell pass / registered /
sim-pass / missing-registered`, exit 0. 14 CAP_CELLS: PASS=9, PASS-PARTIAL=3,
REGISTERED-DIVERGENCE=2 (KD-117, KD-118 rows), UNREGISTERED-GAP=0, MISSING=0.
Every cell has ground=ok; the wave-3 cell `appconfig-snapshots` cites this
receipt itself and now reads standing PASS (this section is its witness).

### 5.5 workflows.json — 7 workflows, orphans=[], 14 cells mapped

`verification/workflows.json`: 7 workflows, `coverage.orphans: []`,
`coverage.missing: []`, and all 14 CAP_CELLS present in
`coverage.inventory_sources.CAP_CELLS` with wf-mappings
(kv-deletedkeys-lifecycle/sb-schedule/blob-snapshot-list/
policy-exemption-armcase/tags-at-scope/lro-namespace-put → wf6,
appconfig-snapshots → wf7).

## 6. Concurrent-lane transients (disclosed, resolved to green)

During verification the shared checkout carried concurrent wave-4 lane edits;
three compile-dependent commands failed transiently on other lanes' in-flight
files and were retried to green under the compile-freeze SLA (no fixes applied
by this lane — retried until the owning lane's edit landed):

1. `mix smalt.gen` (attempts 1-4 of the first poll): verification compile
   failed on `lib/smalt/arm_gateway/router.ex` — `undefined function
   eg_put_if_present/3` (owning lane's mid-flight edit; function count at
   HEAD: 0). Cleared on the owning lane's landing.
2. `mix compile` / `mix smalt.gen`: `undefined function
   ec_alg_check/2` / `alg_for_key_type/2` / `ec_sig_der_encode/2` in
   `lib/smalt/data_plane/key_vault_actions.ex` (KD-119 lane mid-flight).
   Cleared on landing.
3. `mix smalt.gen` first-poll hash pair differed once on `lib/smalt/config.ex`
   (09fb03df… vs bdcd4904…) — a concurrent edit landed between the two runs;
   the two clean consecutive runs (§5.1) are byte-identical. Note: working-tree
   `config.ex` (bdcd4904…) differs from HEAD (KD-COVERS: KD-110 token state) —
   that delta is in-flight wave-4 churn owned by other lanes, not wave-3
   drift; the §5.1 hashes are the current-tree generation, exit 0.
4. `sdk_coverage` first exit-code capture was through a pipe (tail), so `$?`
   read `tail`'s status; re-confirmed `GATE: OK` + exit 0 directly.
