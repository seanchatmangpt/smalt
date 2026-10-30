# Gap 02 Shard — P1 neutral-core shape requirements (input to lane 8)

Lane M2 output, 2026-10-30. Input for the P1 landing of
`priv/ontologies/public-cloud-core.ttl`. Every citation below was re-grepped
from disk THIS SESSION (2026-10-30); two census drifts found and corrected —
`resource_providers.ex` now lives at `lib/smalt/arm_gateway/plug/` and the
`apps/web` harness is not a smalt-tree path (see Corrections).

P1 scope (gap-02 census): L2, L5, L7, L8, L10, L11 (mechanism), L13 — the
7 neutral-core laws. Vocabulary for the core ttl is TOSCA/CIMI/KMIP/security
only (tosca:/cimi:/kmip:/sec:) — zero proprietary IRIs; the zero-proprietary
court is law.

## Shape requirements (7)

### S1 (L2) — generic resource envelope
- **Class**: `tosca:ResourceEnvelope`
- **Wire law**: a PUT body carries top-level `location`; the record echoes
  it verbatim; location is not KV-specific.
- **Citations**: `lib/smalt/arm_gateway/plug/resource_providers.ex:837-847`
  (`build_resource_record/5` — `"location" => Map.get(payload, "location", "eastus")`),
  `:984` (generic put path), `:1637`; provider
  `adapters/terraform-provider-smalt/internal/provider/resource_key_vault.go:249-258`
  (PUT body `"location" => loc`), `:305-310` (Read re-normalize),
  `:338-345` (Update re-emit); `NormalizeLocation` `arm_client.go:528-529`.
- **Shape sketch** (sh:closed):
  ```turtle
  tosca:ResourceEnvelope a sh:NodeShape ;
    sh:closed true ;
    sh:property [
      sh:path cimi:resource.location ;
      sh:datatype xsd:string ; sh:minCount 1 ; sh:maxCount 1 ] ,
    [ sh:path cimi:resource.name ; sh:datatype xsd:string ;
      sh:minCount 1 ; sh:maxCount 1 ] ,
    [ sh:path cimi:resource.type ; sh:kind iri ;
      sh:pattern "^tosca:(compute|storage|network|secret)" ] .
  ```
- **Refuses**: a record whose stored props carry `location` nested ONLY under
  a vendor envelope (e.g. `properties.location`) with no top-level
  `cimi:resource.location` — typed `REFUSED(envelope.missing_location)`.
- **Refusal falsifier**: PUT a record with body
  `{"properties":{"location":"eastus"}}` and no top-level location; the core
  admission layer must refuse it. If the core admits a record that stores a
  location without a top-level envelope slot, the core ttl FAILS non-vacuity.

### S2 (L5) — observable-state disjunction
- **Class**: `sec:StateDisjunctionLaw`
- **Wire law**: a GET of a changed secret either shows the new value or omits
  it AND bumps the etag — a changed secret is never wire-indistinguishable
  from an unchanged one.
- **Citations**: KD-03 row `posh/KNOWN_DIVERGENCES.md:83` (re-read this
  session; polarity corrected 2026-10-30: ARM face echoes verbatim, 8443
  data-plane face never echoes); live probe receipt
  `docs/jira/posh/v26.10.30/gaps/23-secret-echo-staleness.md` (rows for
  `live_f4_test.go:323-333` disjunctive law and
  `resource_key_vault_secret.go:365-368` disjunctive Read).
- **Shape sketch**:
  ```turtle
  sec:StateDisjunctionLaw a sh:NodeShape ;
    sh:closed true ;
    sh:property [
      sh:path sec:state.changeObservableVia ;
      sh:node kmip:SecretValueOrVersion ;
      sh:minCount 1 ] .
  kmip:SecretValueOrVersion a sh:NodeShape ; sh:closed true ;
    sh:xone (
      [ sh:closed true ; sh:property [
          sh:path kmip:secret.value ; sh:datatype xsd:string ; sh:minCount 1 ] ]
      [ sh:closed true ; sh:property [
          sh:path kmip:secret.version ; sh:datatype xsd:string ; sh:minCount 1 ;
          sh:path kmip:secret.etag ; sh:datatype xsd:string ; sh:minCount 1 ] ] ) .
  ```
- **Refuses**: a GET/record where the value is absent AND the version/etag
  are identical to the pre-change observation — typed
  `REFUSED(state.invisible_change)`.
- **Refusal falsifier**: mutate a stored secret, GET it, assert
  (value echoed XOR (version bumped AND etag bumped)); the core admits an
  observation satisfying NEITHER disjunct → FAIL.

### S3 (L7) — created-vs-updated status law
- **Class**: `cimi:EntryStatusLaw` (201 new / 200 existed)
- **Wire law**: PUT answers 201 when the record is new, 200 when it existed.
  Generic across every PUT family, not KV-specific.
- **Citations** (all `lib/smalt/arm_gateway/plug/resource_providers.ex`,
  re-grepped): `:986-1003` (existed? probe → `if(existed?, do: 200, else: 201)`),
  `:1291-1296`, `:1639-1651`, `:3932-3949`, `:4111-4149`, `:5139-5146`;
  same law in `providers/acr_router.ex:163,313-332`;
  `plug/subscription_router.ex:264-286`.
- **Shape sketch**:
  ```turtle
  cimi:EntryStatusLaw a sh:NodeShape ; sh:closed true ;
    sh:property [
      sh:path cimi:entry.creationStatus ;
      sh:in ( 200 201 ) ; sh:minCount 1 ] .
  ```
- **Refuses**: a PUT response with status 201 on an existing record, or 200
  on a genuinely new record — typed `REFUSED(entry.status_mismatch)`.
- **Refusal falsifier**: replay a byte-identical PUT twice; the second
  response must be 200. Second response 201 (or first 200 on a cold key) →
  the core ttl FAILS.

### S4 (L8) — lifecycle vocabulary (neutral LRO)
- **Class**: `cimi:OperationLifecycle` (InProgress → terminal, single writer)
- **Wire the core models**: operation resource with InProgress/terminal
  status, single terminal writer, poll-driven convergence; the 202-header
  ENVELOPE render (Azure-AsyncOperation/Location/Retry-After) stays dialect
  until P3 per gap-02.
- **Citations**: `lib/smalt/arm_gateway/lro.ex:16-28` (contract prose: 202 + Retry-After until delay elapses then 200; single
  terminal writer = Sweeper; read path routes through the writer), headers at
  `lro.ex:28`; `lro_sweeper.ex` single-writer; `engine/lro.ex`.
- **Shape sketch**:
  ```turtle
  cimi:OperationLifecycle a sh:NodeShape ; sh:closed true ;
    sh:property [
      sh:path cimi:operation.status ;
      sh:in ("InProgress" "Succeeded" "Failed") ; sh:minCount 1 ] ,
    [ sh:path cimi:operation.singleTerminalWriter ; sh:datatype xsd:boolean ;
      sh:hasValue true ] .
  ```
- **Refuses**: an operation record with status outside the closed set, or two
  components each claiming the terminal writer role — typed
  `REFUSED(operation.terminal_writer_not_unique)`.
- **Non-vacuity**: mutating a poll observation to status `"Wedged"` must fail
  the closed-shape check; a core that admits it is vacuous → FAIL.

### S4 REFUSAL semantics note (decision-record open question 1)
The neutral lifecycle vocabulary is decision-record open question 1; this
shape is the M2-proposed input, ADMITTED-AS-INPUT only (v26.10.31 in
transition), not admitted core semantics until lane 8 merges and the court
runs. If lane 8 rejects the vocabulary choice, this row stays BLOCKED on the
decision record.

### S5 (L10) — optimistic concurrency
- **Class**: `cimi:ConcurrencyLaw` (etag/If-Match)
- **Wire law**: PutWithETag, `*` honored (RFC 7232 resource-exists), required
  If-Match on lock actions, typed 412 mismatch, 409 on lock-covered scope.
  etag/If-Match is vendor-neutral REST.
- **Citations**: `lib/smalt/arm_gateway/plug/resource_providers.ex:2137-2173`
  (check_lock_precondition: missing If-Match → 412 PreconditionFailed; `*`
  always matches; mismatch → 412); lock 409 mapping
  `:210-216, :264` (ScopeLocked envelope); provider `arm_client.go:357,360`
  (PutWithETag signature); harness cross-check `live_f4_test.go:323-333`
  (etag cross-check leg, per gap-23 receipt rows — receipt-based, not
  re-grepped this session).
- **Shape sketch**:
  ```turtle
  cimi:ConcurrencyLaw a sh:NodeShape ; sh:closed true ;
    sh:property [
      sh:path cimi:resource.etag ; sh:datatype xsd:string ; sh:minCount 1 ] ,
    [ sh:path cimi:resource.ifMatchRequiredOnLockAction ;
      sh:datatype xsd:boolean ; sh:hasValue true ] .
  ```
- **Refuses**: a lock-action PUT with no If-Match (412 law), a mismatched
  If-Match that is admitted, or `*` refused on an existing resource — typed
  `REFUSED(concurrency.precondition_unmet)`.
- **Refusal falsifier**: send a lock action with the WRONG If-Match; the core
  must refuse. If it admits a mismatched If-Match, the core ttl FAILS.

### S6 (L11 mechanism) — deterministic identity mint
- **Class**: `kmip:DeterministicMintLaw`
- **Wire law**: a bare name+scope resolves via uuid5(name|scope) with a fixed
  namespace, emitting a loud local-GUID warning; the Azure built-in GUID
  mapping table is dialect (P2), the MECHANISM is core.
- **Citations**: provider
  `adapters/terraform-provider-smalt/internal/provider/resource_remaining_v1.go:1369-1374`
  (FABRICATION NOTICE), `:1413-1454` (`resolveRoleDefinitionInput` — mint of
  `value + "|" + scope`, `:1428`), `:38` (`mintDeterministicGUID`), `:1478`
  (assignment-name mint `scope + "|" + rdID + "|" + principal`), KD-09 row
  `posh/KNOWN_DIVERGENCES.md:89` (re-read this session).
- **Shape sketch**:
  v5 UUID = SHA-1(namespace_uuid + name), `name := value|scope`; fixed
  namespace constant; mint emits a warning diag on every resolution.
  ```turtle
  kmip:DeterministicMintLaw a sh:PropertyShape ;
    sh:path kmip:identity.mint ; sh:datatype xsd:string ;
    sh:pattern "^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$" .
  ```
- **Refuses**: a non-v5 mint (v4/random where determinism is required), or a
  silent mint (no warning) — typed `REFUSED(identity.nondeterministic_mint)`.
- **Falsifier**: mint the same (name, scope) twice → byte-identical GUIDs;
  different (name, scope) → different GUIDs; a mint that is not a function of
  (name, scope) → core FAIL.

### S7 (L13) — tags full-replace + null-when-empty + covering-scope lock
- **Class**: `tosca:MetadataReplaceLaw` + `cimi:ScopeLockLaw`
- **Wire law**: tag PUT is a FULL REPLACE (omitted/empty tags remove stored
  tags, GET renders `"tags": null`); a covering ReadOnly lock refuses writes,
  a covering CanNotDelete/ReadOnly lock refuses deletes with typed 409
  ScopeLocked.
- **Citations**: `lib/smalt/arm_gateway/plug/common.ex:100-107`
  (normalize_tags null-when-empty), tags full-replace SHIM-COURT comment
  `lib/smalt/arm_gateway/tags_locks.ex` (FR-5 re-witness block); lock
  mapping in `plug/resource_providers.ex:210-216, :264`; provider tags law
  in `adapters/terraform-provider-smalt/internal/provider/resource_key_vault.go:333-345`
  (Update: empty tags → remove).
- **Shape sketch**:
  ```turtle
  tosca:MetadataReplaceLaw a sh:NodeShape ; sh:closed true ;
    sh:property [ sh:path cimi:resource.tags ; sh:class cimi:TagMap ;
                  sh:maxCount 1 ] .
  cimi:ScopeLockLaw a sh:NodeShape ; sh:closed true ;
    sh:property [ sh:path cimi:lock.level ;
      sh:in ("ReadOnly" "CanNotDelete") ; sh:minCount 0 ] ,
    [ sh:path cimi:lock.refuseOnCoveringScope ; sh:datatype xsd:boolean ;
      sh:hasValue true ] .
  ```
  Refusal: a covering CanNotDelete lock admitting a DELETE →
  `REFUSED(lock.scope_locked)`, core FAIL if admitted.
- **Refuses**: (a) PATCH-merge semantics on a PUT body (full-replace
  violation), (b) a DELETE under a covering lock admitted without 409 —
  typed `REFUSED(metadata.merge_semantics_on_put)` /
  `REFUSED(lock.scope_locked)`.
- **Refusal falsifier**: PUT `{}` tags over stored `{a: b}` → GET must render
  `tags: null`; GET renders `{a: b}` → core FAIL. DELETE under covering
  CanNotDelete lock returning 200 → core FAIL.

## Census drift corrections (gap-02 table vs current code)

1. **resource_providers.ex path moved**: gap-02 cites
   `lib/smalt/arm_gateway/resource_providers.ex` for L2/L7/L10/L13; the
   module now lives at `lib/smalt/arm_gateway/plug/resource_providers.ex`.
   Line drift too: L7's "1412-1418" is a Service-Bus rule PUT (still a 201
   site, but the generic existed?-probe sites are :986-1003, :1291-1296,
   :1639-1651, :3932-3949, :4111-4149, :5139-5146); L10's If-Match gate is
   :2137-2173 (was cited 2137-2217 — close, gate body is 2141-2173).
2. **apps/web harness paths do not exist in the smalt tree** (L1/L2/L5
   harness citations `apps/web/test/harness/...`): no `apps/` dir at smalt
   root. Those citations belong to the posh tree (posh/web or the harness
   repo); gap-02 should re-home them. Gap-23's receipt rows were used as the
   receipt-based substitute for L5's harness legs.

## Close condition

Gap-02's status row is updated (same session) to note this shard exists and
is lane-8-ready. Shard carries 7 shape requirements, each with a refusal
falsifier. Lane 8 merges these into `priv/ontologies/public-cloud-core.ttl`
(lane 8 owns the ttl; this lane does not edit it).
