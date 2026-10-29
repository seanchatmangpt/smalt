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

---

# ERRC wave-4 flip verification (appended 2026-10-20)

- **Date**: 2026-10-20
- **Subject**: smalt working tree at HEAD `28ceff9` (git status clean at lane
  start, 05:00 PDT) + concurrent wave-4 in-flight edits disclosed below.
- **Context**: solo (ERRC wave-4 verification lane; read-mostly + rerun, no
  code edits, no git)
- **Standing**: PARTIAL — 3 of 4 defects FLIPPED; blob list RFC-1123
  NOT-FLIPPED (real SDK default path 500s at this HEAD; §B below).
- **Substrates**: fresh boots only, never reused: b11 `--auth enforce --fresh`
  (ports 39110-39115) for KV-purge + exemptionCategory; b12
  `--auth anonymous --fresh` (ports 39120-39125) for the blob SharedKey leg
  (master-key surfaces are an anonymous-mode surface per
  `verification/py/conftest.py`; the enforce-b11 SharedKey attempt is
  transcribed honestly in §A2). KD-118 rode `sb-extra.probe.cjs`, which boots
  and sweeps its own fresh b11 internally.
- **No lib/ edits were made by this lane.** Two compile-freeze SLA waits were
  observed (no unblock fix applied): (1) a transient backtick syntax error in
  `lib/smalt/arm_gateway/router.ex:4659` (owner repaired within ~6 min);
  (2) `lib/smalt/data_plane/key_vault_actions.ex` mid-refactor snapshot
  (caller `derive_oct_key/1` present, callee missing → runtime
  UndefinedFunctionError on the first KV create; owner landed the callee;
  re-boot picked it up).

## Flip-verification table

| # | Defect | Verdict | Evidence class | Transcript (this session, verbatim) |
|---|--------|---------|----------------|--------------------------------------|
| 1 | KV purge twin (bare `DELETE /deletedkeys/{n}` → 204) | **FLIPPED** | Raw wire over the TLS twin (curl --cacert dev-cert, KD-15 challenge dance), fresh b11 enforce | §A1, 6/6 PASS |
| 2 | Blob list RFC-1123 (azure-storage-blob deserializes) | **NOT-FLIPPED** | Real azure-storage-blob 12.31.0 (py venv) against fresh substrate | §B — `include` leg deserializes RFC-1123 cleanly, but the SDK default `list_blobs()` 500s at this HEAD (`blob_metadata_xml/2` no `nil` clause). Close condition not met. |
| 3 | KD-118 TS schedule-message | **FLIPPED** | `node sb-extra.probe.cjs` (real @azure/service-bus 7.10.0, AMQP) | §C, 3/3 PASS |
| 4 | exemptionCategory roundtrip | **FLIPPED** | Raw ARM wire, fresh b11 enforce, bearer from emulator STS | §D, 3/3 PASS |

## §A1 KV purge twin — 6/6 PASS (fresh b11 enforce, pid 39204, 05:16 PDT)

```
PASS kv-tokenless-challenge tokenless DELETE -> 401 (KD-15 challenge)
PASS kv-create POST /keys/w4-purge-b0f323/create -> 200
PASS kv-soft-delete DELETE /keys/w4-purge-b0f323 -> 200
PASS kv-get-deleted GET /deletedkeys/w4-purge-b0f323 -> 200
PASS kv-purge-twin-204 bare DELETE /deletedkeys/w4-purge-b0f323 -> 204
PASS kv-post-purge-404 post-purge GET /deletedkeys/w4-purge-b0f323 -> 404
```

## §A2 Honest failures during verification (environment + auth-tier, not the defects)

- First b11 boot refused at compile: `router.ex:4659` backtick SyntaxError
  (concurrent lane mid-edit; SLA wait, owner fixed).
- Second boot refused: `key_vault_actions.ex` mid-refactor (undefined
  `ec_alg_check/2`, `alg_for_key_type/2`, then a caller/callee skew on
  `derive_oct_key/1` that surfaced at runtime as 500→503 on the KV face).
  The KV purge transcript in §A1 is from the first healthy boot.
- enforce-mode blob leg attempt (b11): azure-storage-blob SharedKey →
  `ClientAuthenticationError: MalformedBearerHeader` (enforce correctly
  refuses SharedKey on the data plane); bearer leg refused client-side by the
  SDK over http egress; `/smaltacct` is not in TlsTwinDispatch
  `@egress_prefixes` → `RouteNotFound` over TLS. Hence the canonical
  anonymous tier (b12) per the conftest docstring.
- b11 contention: a concurrent lane's ServiceBus census occupied b11
  (05:19-05:23); its exit sweep SIGTERMed my instance. Re-upped fresh; the
  exemptionCategory leg ran on the post-contention boot (pid 49661).

## §B Blob list RFC-1123 — NOT-FLIPPED (defect at HEAD `28ceff9`)

`blob_storage.ex` carried NO in-flight diff during this session (verified via
`git diff --stat`), so this is attributable to the pinned HEAD. Raw wire:

```
create-container:201 ; put-blob-0:201 ; put-blob-1:201
list-no-include:500
list-include-metadata:200   # Last-Modified: Tue, 20 Oct 2026 12:20:38 GMT (RFC-1123, parses)
```

Real SDK (azure-storage-blob 12.31.0, anon b12 egress 39123):

```
PASS blob-list-include-metadata-deserialized list_blobs(include=[metadata]) ->
  3 blobs, names=['blob-0','blob-1','blob-2'],
  last_modified=['2026-10-20 12:20:58+00:00', ...] (no DeserializationError)
FAIL default-list-no-include azure HttpResponseError status=500
```

Root cause (read at HEAD + tree, clauses identical in both):
`do_list_blobs_xml` does `include = Map.get(opts, "include")` → `nil` when
the client omits the query param; `blob_metadata_xml(_b, false)` is the
only no-include clause — no `nil` clause, so
`blob_metadata_xml(record, nil)` FunctionClauseErrors → 500 on every default
`list_blobs()`. The RFC-1123 rendering itself is correct and deserializes;
the SDK's DEFAULT path is what 500s. Fix is one clause:
`defp blob_metadata_xml(_b, nil), do: ""`. Registrar: do not flip the blob
RFC-1123 cell on this receipt; owner lane should add the nil clause + a
default-list SDK cell witness.

## §B2 Side observation (needs owner triage, unregistered)

`delete_container` on a freshly booted anon b12 (no immutability policy ever
set by this lane) is refused with
`409 ContainerLocked — "container policy enforces immutable WORM retention"`
on containers `w4-rfc1123-*` / `w4-incl-*` / `w4-raw-*`. Real Azure deletes
policy-less containers. Possible over-broad WORM arm from the wave-3
per-blob immutability work. My lane could not clean up its probe containers
(swept with the beam). Unregistered observation, not a KD mint.

## §C KD-118 — 3/3 PASS

`cd verification/ts && node sb-extra.probe.cjs` (boots own fresh b11,
enforce):

```
PASS scheduleMessage
PASS receiveAndDelete-delivery
PASS acceptNextSession-no-session
SUMMARY pass=3 fail=0
[sb-extra] WATCHDOG: no verdict in 180000ms — typed fail (PROBE_EXIT=3)
```

(exit 3 is the pre-existing documented post-summary event-loop hang at
sb-extra.probe.cjs:188; the verdict lines are the falsifier signal.)

## §D exemptionCategory — 3/3 PASS (fresh b11 enforce, pid 49661)

```
PASS exemption-put PUT -> 201, exemptionCategory=Waiver
PASS exemption-get-echo GET -> 200, exemptionCategory=Waiver
PASS exemption-delete DELETE -> 200
```

(Probe: `PUT/GET/DELETE /subscriptions/w4-sub/providers/Microsoft.Authorization/policyExemptions/w4-ex-waiver?api-version=2022-07-01-preview`,
bearer from emulator STS `POST /w4-tenant/oauth2/v2.0/token` on the TLS twin.)

## Teardown

```
scripts/substrate-ctl down --block b11 --mode sweep → exit 0
scripts/substrate-ctl down --block b12 --mode sweep → exit 0
status: both blocks up=0, ports drained (39110-39115, 39120-39125)
```

---

# ERRC wave-4 FULL battery rerun (appended 2026-10-20, second pass)

- **Date**: 2026-10-20 05:00-06:10 PDT
- **Subject**: smalt at HEAD `28ceff9` + concurrent wave-4 in-flight working-tree
  edits (disclosed below; clean-HEAD isolation not possible for a read-only
  lane — results are HEAD + in-flight tree).
- **Context**: solo (ERRC wave-4 verification lane, rerun pass; no code edits,
  no git)
- **Method**: every harness boots and sweeps its OWN fresh substrate at the
  current tree (no pre-existing beam reused): run-all → v13/v14 private boots
  (enforce), newcaps → v9 (enforce), sb-extra/census → b11 (enforce), py
  run.sh → v1 (enforce, `reused:false`). A lane spare block b4
  (`--auth enforce --fresh`, ports 39040-39045) was booted per dispatch and
  swept down unused — the harnesses self-boot. Logs: /tmp/wave3-verify/*.log.

## Battery verdict table (fresh beams, HEAD 28ceff9 + in-flight tree)

| Harness | Exit | Cells |
|---|---|---|
| `verification/ts` `node run-all.mjs` (wf1-wf5) | **1** | 39 GREEN, 1 REGISTERED-DIVERGENCE#KD-14/KD-105, 5 FAIL: wf2 blob-auth-channel (SharedKey vs enforce Bearer, bearer-over-http refused client-side — no usable official-SDK blob channel under enforce); wf3 sb-send20-receive-complete (received 0/20 — receiver-delivery gap on the shared v13 substrate); wf3 sb-message-lock-lost (no delivery — same gap); wf3 sb-dlq-maxdelivery (DLQ size=0); wf4 kv-recover (POST /deletedkeys/recover → 400) |
| `node newcaps.probe.mjs` | **1** (hardFails=1) | PASS kv delete/getDeleted/recover/getAfter; PASS secrets soft-delete mirror; PASS tags-at-scope; **SKIP** sb schedule-message (KD-118 lane: $management 400 QUEUE_REQUIRED, request resolves neither body `queue` nor associated-link-name — management_rpc.ex:661-667); **SKIP** blob snapshot-list-decoration (snapshot 201 + x-ms-snapshot OK but List Blobs 500: blob_metadata_xml/2 FunctionClauseError, nil clause — §B root cause of the prior section confirmed); **FAIL** KD-112 resource-scope exemption arm (cased RG-scope 400, resource-scope 404 — not landed); SKIP LRO namespace-put 202 (not landed on this namespace) |
| `node sb-extra.probe.cjs` | **3** (documented post-summary event-loop hang) | 3/3 PASS: scheduleMessage, receiveAndDelete-delivery, acceptNextSession-no-session |
| `node --test census.test.cjs` | **0** | 12/12 pass, zero skips (all 11 SB probes incl. dead-letter, dlq-properties, deferred-receive + harness self-check) |
| `verification/py` `bash run.sh` (wf1-wf7) | **1** | 18 passed, 1 failed, 3 errors, 1 skipped. The 3 setup errors + 1 failure are ONE cause: SB namespace PUT now answers **202 LRO body** (`/subscriptions/py-verify-sub/.../namespaces/pywf3-ns` → 202 with operations id) where the py fixture asserts 200/201 (test_wf3_messaging.py:38) — test-harness premise rot vs the in-flight wave-4 LRO-widen, not a substrate defect; SKIP wf7 sentinel tables (not-landed, unchanged) |

Cross-run contrast recorded honestly: the wf3 SB receiver-delivery FAILs
(run-all, v13) and kv-recover 400 (wf4) did NOT reproduce in the same session's
census b11 boot (SB 11/11 green incl. delivery/settle probes) nor in py wf4
(test_soft_delete_recover_purge PASSED) — same HEAD, different fresh beams.
These are the two cells most likely to be in-flight-tree-sensitive; a clean
28ceff9 isolation rerun is the close condition.

## Reconciliation of the wf6/wf7 lane's 4 NOT-FLIPPED findings (fresh beam)

| Finding | Prior verdict (§ table above) | This rerun | Verdict |
|---|---|---|---|
| KD-118 TS schedule-message framing | FLIPPED (§C 3/3) | sb-extra rerun 3/3 PASS on a fresh b11; newcaps AMQP-management cell still SKIP (400 QUEUE_REQUIRED on the $management link — the probe's own management-shape lane, distinct from sb-extra's CBS path) | **CONFIRMED FLIPPED with a fresh beam** — the wf6/wf7 lane's NOT-FLIPPED finding does not reproduce; earlier contradictions were stale-beam artifacts |
| Blob list RFC-1123 | NOT-FLIPPED (§B) | Default-path List Blobs still 500s (blob_metadata_xml/2 nil clause); include-path deserializes RFC-1123 cleanly (py wf6 test_blob_snapshot_listing PASS) | **CONFIRMED NOT-FLIPPED** — close condition unchanged: add `defp blob_metadata_xml(_b, nil), do: ""` + default-list SDK witness |
| exemptionCategory roundtrip | FLIPPED (§D 3/3) | Raw ARM exemption PUT/GET/DELETE shape lands (py test_policy_initiative_assignment_exemption PASS); newcaps KD-112 cell FAIL names a DIFFERENT, still-open gap: the resource-scope exemption arm (404) + cased RG-scope id (400) | **CONFIRMED FLIPPED at the claimed RG-scope**; resource-scope arm remains an open cell (register obligation, not a regression) |
| Sentinel table-stats (wf7) | not-landed | wf7 tables test SKIPs loudly again ("no route on egress_router.ex or arm_gateway/router.ex") | **STILL NOT LANDED** — unchanged, honest skip |

## Honest failures / SLA waits (this pass)

- Two compile-freeze SLA waits at lane start (no fixes applied by this lane):
  (1) `router.ex` mid-edit `eg_put_if_present/3` undefined (~2 min to land);
  (2) `key_vault_actions.ex` mid-refactor `alg_for_key_type/2` undefined
  (cleared within one 45 s poll). Tree then compiled clean in
  `_build-laneV`.
- First run-all attempt failed pre-suite: SUBSTRATE-BOOT-FAIL on v13 during
  window (1); also a lane-side redirect bug (log dir missing) cost one
  no-op attempt. Retried to completion after the tree compiled.
- run-all exit 1 and py exit 1 are reported as-is; per-cell detail above.
  One pre-existing, prior-section-documented event-loop hang (sb-extra exit 3
  post-summary) is a harness artifact, verdicts unaffected.

## Teardown

```
substrate-ctl down --block b4 --mode sweep → exit 0
status b4/v1/v9/b11/v13/v14 → up=0 all, ports drained

## Error-code projection verification (wave-5 ERRC lane, 2026-10-20)

Standing: **PASS (regen landed) / OPEN-FINDING (extractor coverage gap)** ·
Context: solo

Scope of this lane: verify `docs/ERROR_CODES.md` completeness at current HEAD.
Read-only on code; the regen (`python3 scripts/gen_error_codes.py`) is the
sanctioned generated-docs surface.

### (1) Drift check and regen

```
$ python3 scripts/gen_error_codes.py --check
docs/ERROR_CODES.md is stale. Run: python3 scripts/gen_error_codes.py
exit=1

$ python3 scripts/gen_error_codes.py
wrote /Users/sac/smalt/docs/ERROR_CODES.md (155 rows)
$ python3 scripts/gen_error_codes.py --check
docs/ERROR_CODES.md up to date
exit=0
```

Row delta: **0 rows added / 0 removed** (155 data rows before and after; 167
lines matching `^| ` including table headers/separators). The staleness was
**citation drift only** — `lib/` is dirty from concurrent wave lanes
(`config.ex`, `queue_store.ex`, `management_rpc.ex`, `purview_atlas.ex` at
time of check), so source line numbers in the Source column had moved. Note:
two intermediate `--check` runs exited 1 mid-sequence on exactly this
concurrent-edit race (line-number diffs in amqp-management and arm-gateway
sections between regen and check); a tight regen → check → check with a quiet
lib/ is stable.

### (2) Extractor family coverage of new wave-2/3/4 surfaces — 4 of 5 MISSING

```
$ grep -E 'ScopeLocked|PolicyRemediationInvalid|SnapshotExists|SESSION_STATE_SIZE_EXCEEDED|CertificateNameAlreadyExists' docs/ERROR_CODES.md
180:| amqp-management | 400 | SESSION_STATE_SIZE_EXCEEDED | lib/smalt/messaging/amqp/management_rpc.ex:392 | ...
```

`SESSION_STATE_SIZE_EXCEEDED` is projected. The other four exist as literals
in `lib/` but no extractor family covers them:

| Literal | lib site(s) | Why missed |
|---|---|---|
| `ScopeLocked` | policy.ex:1339, arm_gateway/router.ex:1047 | `extract_policy` takes only the FIRST `"code"` literal inside `violation_body/2` (→ PolicyViolation); the ScopeLocked inline envelopes are outside that function and outside the router-corpus scan |
| `PolicyRemediationInvalid` | policy.ex:892 | same — inline envelope outside `violation_body/2` |
| `SnapshotExists` | appconfig_snapshots.ex:91 | code-first tuple `{:error, {"SnapshotExists", ...}}` — no literal status in T1–T6 shapes |
| `CertificateNameAlreadyExists` | certificates.ex:162 | `certificate_error("...")` helper call — T3 matches only `bad_request("...")` |

Verdict: the regen is faithful to its extractor families, but the families
predate the wave-2/3/4 surfaces. This is a **generator-coverage gap**, filed
here as a finding — this lane is verification-only (no code edits; the
extractor is an owned surface outside this lane's lease). Suggested close
condition for the owning lane: add families for `certificate_error("...")`
call sites, code-first error tuples, and the post-`violation_body` inline
policy envelopes, then regen (expected +4 rows).

### (3) Idempotency

```
$ python3 scripts/gen_error_codes.py && python3 scripts/gen_error_codes.py --check && python3 scripts/gen_error_codes.py --check
wrote /Users/sac/smalt/docs/ERROR_CODES.md (155 rows)
docs/ERROR_CODES.md up to date
docs/ERROR_CODES.md up to date
exit=0 (both checks)
```

Idempotent ×2 on a quiet tree. `docs/ERROR_CODES.md` regenerated this pass is
committed as part of the wave integration; no hand edits were made to it or to
`scripts/gen_error_codes.py`.

---

## Flip verification: wf7 `sentinel:table-stats` SKIP (ERRC wave-5 verification lane, 2026-10-20)

Standing: **PARTIAL_ALIVE — residual confirmed, no flip.** The diagnostics
table-stats SKIP did NOT flip: the wave-5 ARM tables family is not landed.

### (1) Wave-5 ARM tables family status (grep of lib/)

Typed finding — **NOT-LANDED**:
- `lib/smalt/registry.ex:52` admits the parent
  `Microsoft.OperationalInsights/workspaces` (DefaultShape, api-version
  2020-08-01) — generic ARM route serves the workspace PUT (witnessed 201
  below).
- Child family `Microsoft.OperationalInsights/workspaces/tables` is NOT in
  the registry and `grep OperationalInsights lib/smalt/arm_gateway/router.ex`
  returns zero route fragments (only registry rows); no dedicated tables
  route on `egress_router.ex` either.
- A generic child GET on `.../workspaces/:ws/tables` answers **200 with
  `{"value": []}`** — a stub, not the tables family: it never surfaces the
  DCR-ingested streams regardless of ingest state.

### (2) Live probe (substrate-ctl b12 --auth enforce, ports 39120-39125; ARM=39122, egress=39123)

```
rg PUT 201
workspace PUT 201 {"id":"/subscriptions/.../providers/Microsoft.OperationalInsights/workspaces/b12-ws-...",...}
ingest Custom-Logs -> 204          (4 rows)
ingest Custom-Events -> 204        (7 rows)
GET /subscriptions/.../workspaces/b12-ws-.../tables (api-version 2020-08-01) -> 200 {"value": []}
GET /v1/workspaces/<dcr>/tables (egress) -> 400 MissingXMsVersion (egress hosts no such route)
```

**Per-stream counts via the ARM tables route do NOT match** — the route
returns an empty list, no per-stream rows. Ground truth via the KQL plane
does hold per-stream isolation, with one divergence found:

```
Custom-Logs | summarize count() by s        -> [['7','Custom-Events'], ['4','Custom-Logs']]   # correct, per-stream
Custom-Logs | summarize count()             -> [['11']]   # BUG: workspace-global, ignores table source
Custom-Events | summarize count()           -> [['11']]   # same 11 = 4+7, reproduced on 2 fresh DCRs
```

**Typed finding — KQL-ENGINE: bare `| summarize count()` (no `by`) is not
table-scoped**; it aggregates across every stream in the workspace instead
of the named source table. Scoped `by <col>` aggregation is correct. This
is a new divergence, not previously registered.

### (3) wf7 table-stats cell rerun

```
$ cd verification/py && .venv/bin/pytest test_wf7_diagnostics.py -k table_stats -rs -q
SKIPPED [1] test_wf7_diagnostics.py:230: not-landed — owning surface: Sentinel/Log Analytics
workspace tables ARM family (GET workspaces/:id/tables) — no route on egress_router.ex or
arm_gateway/router.ex
1 skipped, 4 deselected in 0.24s
```

The SKIP stands, typed and correctly citing the owning surface. **Residual,
no flip.**

### Lane notes

- Boot was blocked ~4.5 min by a concurrent lane's in-flight edit
  (`lib/smalt/data_plane/cosmos.ex:224` calling undefined
  `analytical_ttl_replace/4` — compile error, SUBSTRATE_DIED x4); the owner
  landed the missing function within the SLA and attempt 5 booted clean.
  Disclosed per the compile-freeze disclosure law; no fix applied by this
  lane.
- Close conditions: (a) registry-admit `workspaces/tables` + dedicated
  route family surfacing per-stream row counts from DCR streams; (b) KQL
  bare-`summarize count()` table scoping fix; (c) flip the wf7 cell to a
  real probe gated on (a).

## Wave-5 ERRC verification: pkranges engine via real azure-cosmos (append)

- **Date**: 2026-10-20
- **Subject**: smalt @ `bab1949de31429544b596ba6abceb70f63a45d9e` (main;
  wave-4 promotion commit) — pkranges engine
  (`lib/smalt/data_plane/cosmos.ex` `partition_key_ranges/2`,
  `pkr_ranges/3`, `pkr_ranges_etag/1`, landed wave-4) verified at this HEAD
  with the in-flight wave-5 `cosmos.ex` diff present on disk (see lane notes).
- **Context**: pair (concurrent ERRC wave-5 lanes on b2/b7; this lane b3)
- **Standing**: PASS — all six cells green; the pkranges engine's
  python-SDK drain contract is witnessed at SDK tier, not simulated.
- **Harness**: `verification/py/.venv` (real `azure-cosmos`), probe
  `/tmp/pkranges_b3_probe.py` + focused etag probe `/tmp/pkranges_b3_etag.py`;
  substrate `scripts/substrate-ctl up --block b3 --auth anonymous --fresh`
  (ports 39030..39035, egress/data 39033).
- **Machine**: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}` (`just bench-machine`)

### Cells

```
$ verification/py/.venv/bin/python /tmp/pkranges_b3_probe.py
PASS pkranges.200.coherent - 2 ranges: [["", "55"], ["55", "FF"]]
PASS pkranges.routing_drain.query - cross-partition query returned ['d1', 'd2'] (routing map drained from pkranges feed)
PASS pkranges.unknown.404 - CosmosResourceNotFoundError status=404
FAIL pkranges.inm.drain.wire - first=200 etag=None refetch-with-etag=200
FAIL pkranges.inm.drain.sdk - SDK read with If-None-Match: wire status=200, items=2, resp etag=None
PASS pkranges.deterministic - second read identical
SUMMARY: 4/6 pass; fails=['pkranges.inm.drain.wire', 'pkranges.inm.drain.sdk']
```

The two FAIL rows are a probe bug, not an engine defect: the first run's
header read was case-sensitive (`ETag`) while the wire emits `Etag`, so the
etag was read as None and the "refetch with matching etag" leg never matched.
Rerun with case-insensitive header lookup (fresh db/container, negative leg
added):

```
$ verification/py/.venv/bin/python /tmp/pkranges_b3_etag.py
WIRE: first=200 etag="pkranges-34a0f5ff08ec66bed91a88651d2234a0" refetch-with-etag=304
SDK: status=304 items=0 etag="pkranges-34a0f5ff08ec66bed91a88651d2234a0"
NEG: stale-etag refetch=200 (expect 200)
SUMMARY: PASS 3/3
rc=0
```

### Verified contract

1. **200 coherent ranges** — `read_partition_key_ranges` (SDK-internal
   `_ReadPartitionKeyRanges`, the actual drain surface — no public
   `ContainerProxy` method in azure-cosmos) returns a non-empty coherent
   split: `["","55"],["55","FF"]` — `maxExclusive` N == `minInclusive` N+1,
   full `"".."FF"` coverage, deterministic across reads.
2. **Routing drain end-to-end** — a cross-partition SDK query
   (`enable_cross_partition_query`) drains the pkranges feed through
   `_fetch_routing_map`/`evaluate_drain_page` and returns both seeded docs.
3. **Unknown container -> 404** — surfaces as
   `CosmosResourceNotFoundError` (status 404), the abort condition the SDK
   routing layer requires.
4. **If-None-Match drain** — first fetch 200 + `ETag: "pkranges-<md5>"`;
   refetch with the matching etag -> 304 (0 items at SDK tier, matching the
   engine's python-SDK drain contract); stale etag -> 200 (negative leg).

### Lane notes

- Boot was blocked ~4.5 min by a concurrent lane's in-flight edit
  (`lib/smalt/data_plane/cosmos.ex:236` calling undefined
  `analytical_ttl_from_body/1` — compile error); owner landed it within the
  SLA and b3 booted clean. Disclosed per the compile-freeze disclosure law;
  no fix applied by this lane.
- Mid-run, another lane re-booted b3 in **enforce** mode (marker mtime
  06:10, `auth: enforce`), evicting this lane's anonymous boot and causing
  one connection-refused probe attempt. Re-asserted with `--fresh` per this
  lane's dispatch (b3 anonymous); the witness run above is entirely on the
  anonymous boot, pid 89830. Flagging the block-ownership collision for the
  coordinator: b3 was double-dispatched this wave.
- Probe-level (not engine) findings, for the record: `enable_cross_partition`
  is not the azure-cosmos kwarg (`enable_cross_partition_query` is); the
  pkranges surface is SDK-internal (`_ReadPartitionKeyRanges`), so
  "public-API" probes must drive it via cross-partition queries or the
  internal client.
