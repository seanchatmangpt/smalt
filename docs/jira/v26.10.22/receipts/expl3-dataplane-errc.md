# EXPL-3: data_plane + messaging protocol-shape ERRC sweep

**Standing**: PARTIAL_ALIVE — findings are code-read-confirmed against
`lib/smalt/data_plane/*` + `lib/smalt/messaging/*` at main `7dcdd9d`
(read-only sweep; no finding was executed as a probe/repro, so each carries
SUSPECT-until-repro'd standing for the repair lane to confirm first).
**Context: solo**

Surface: 22,403 lines across 32 data_plane files + 14 messaging files.
Excluded per lane contract: SPOF-A/B, ja15/ja16/ja-r1/r2/r3, BK-65/87/112,
W1–W6 (expl1-workspace-errc.md).

## Findings (ranked)

### F1 — TOP TICKET: blob service-properties envelope-absent body silently ADMITS and MUTATES STATE (W1 class)

`lib/smalt/data_plane/blob_soft_delete.ex:58-78` (`set_delete_retention_policy/2`)
and `:109-118` (`set_versioning_enabled/2`).

The XML envelope regex fails to match a malformed body → the `_ ->` fallback
**stores `enabled: false` and returns 200**. A PUT of garbage XML (or a body
with the wrong envelope — e.g. a truncated document, or any XML document that
does not contain the tag) to Put Blob Service Properties is treated as a
"clear" operation: silent 200 + state mutation. Real Azure answers 400
InvalidXmlDocument for a non-empty body lacking the expected envelope;
an empty body is the legitimate "clear" case.

This is the W1 class exactly: the guard admits on unexpected response shape,
and worse than the W1 template — it also writes state (disables an active
soft-delete policy / versioning on the account) with a success verdict.

**Repair shape**: distinguish three cases — empty body (clear, 200),
envelope-present (parse), non-empty-but-envelope-absent (typed 400
InvalidXmlDocument). Falsifier for the repair court: PUT
`<foo/>` to the service-properties route must 400, must NOT flip a previously
enabled soft-delete policy, and the existing legal clear path (empty body)
must still 200.

### F2 — queue TTL parse fails open to a silent default (asymmetry inside queue_storage.ex)

`lib/smalt/data_plane/queue_storage.ex:556-564` (`parse_ttl/1`):
`Integer.parse` failure or `n <= 0` **silently falls back to
`@default_ttl_ms`** (7 days) instead of a typed 400. Every sibling parser in
the same file (`parse_numofmessages`, `parse_maxresults`,
`parse_visibility_timeout`) typed-400s malformed input
(`InvalidQueryParameterValue`/`InvalidHeaderValue`); `parse_ttl` is the lone
fail-open outlier. A client sending `x-ms-ttl=abc` or `x-ms-ttl=-1` gets a
message enqueued with a default TTL it never asked for — silent behavior
substitution, not a refusal.

**Repair shape**: align with siblings — `{n, ""} when n > 0 -> n*1000;
_ -> {:error, 400, "InvalidHeaderValue", "x-ms-ttl ..."}`. Falsifier: PUT
message with `x-ms-ttl: abc` must 400, and the msg-enqueue outcome must not
occur.

### F3 — MHSM release policy: degenerate empty constraint sets admit ALL releases (fail-open to allow-all)

`lib/smalt/data_plane/mhsm.ex:75-95` (`policy_groups/1` + `evaluate_policy/2`):
`%{"anyOf" => []}`, `%{"allOf" => []}`, `%{"assertions" => []}` all reduce to
`[]` groups → `:ok` — **an unconstrained allow-all release**. The module doc
claims "fail-closed: a structurally unresolvable policy ... never allows", and
real MHSM requires ≥1 assertion; an empty `anyOf` is vacuously
nothing-matches and must refuse.

Note: this policy is stored at key creation; the admit happens at RELEASE
time (403 KeyReleasePolicyViolation vs :ok), so the fail-open is on the
release-admission gate, one hop from key material exit. Same surface as
BK-117b's typed-exit discipline but opposite polarity: it is a typed :ok on a
shape the doc says must refuse.

**Repair shape**: empty `anyOf` → refuse (no group can match); empty
`allOf`/`assertions` → refuse at policy-evaluation with 403
KeyReleasePolicyViolation (or 400 at key-create validation). Falsifier: create
key with `release_policy = %{"anyOf" => []}`, attempt RELEASE with a fully
satisfying attestation token → must 403, must be :ok-today → must-403 flip.

### F4 (low) — queue message-text envelope looseness is documented-but-real

`queue_storage.ex:569-590`: `parse_message_text`/`extract_text` accept any
body as raw text when no `<MessageText>` envelope is present (documented
"Accepts the Azure envelope, a bare wrapper, or a raw body"). Deliberate
looseness, but it means `<QueueMessage>`-less arbitrary XML is stored as
message content where real Azure 400s InvalidXmlDocument. Low: no state
corruption (F1's aggravator is absent) — content-only.

### F5 (info) — cosmos pk-header dead defensive branch carries a comment claiming the 400 property

`cosmos.ex:~1940-1955`: inside `scan_query_docs`, the
`PartitionKey.parse(raw) -> :error -> docs` branch would silently cross-partition
scan, but it is unreachable (the `with` runs `query_pk_check` first, which
400s malformed headers — the comment at `cosmos.ex:2188-2191` is accurate).
Not a defect: it is unreachable defensive dead code whose inline comment
("A PRESENT but malformed header is a 400 below") describes a property held by
a *different* function. Premise-rot adjacent: a future refactor that drops
`query_pk_check` from the `with` would silently regress to a cross-partition
leak with the comment still claiming the 400. Suggest folding the dead branch
into a raise/`_ -> docs` comment naming `query_pk_check` as the holder of the
property.

### F6 (info) — cosmos_authz SAS token gate is substring-based

`cosmos_authz.ex:276-277`: resource-prefix version check is
`String.contains?(prefix, "&ver=1.0&")` (or exact-match special case) and the
signature check is `byte_size(sig) > 0 and not contains " "`. Deliberate
emulator looseness on an enforce-mode auth surface with no court receipt named
in-file. Info-only for the coordinator: if this is meant to be parity, it
needs a KD row; if deliberate, an in-file comment naming the divergence
(KD-register discipline).

## Clean (audited, no finding)

`cosmos.ex` query whitelist + CosmosSql fail-closed grammar (typed 400
SyntaxError/InvalidQuery, KD-06/KD-93 receipts in-line), continuation-token
version/container/prefix binding, `query_pk_check` fail-closed;
`blob_storage.ex` `parse_block_list_xml`/`parse_signed_identifiers` typed-400
on non-XML (SHIM-COURT R5 atom-safety note); `key_vault_actions.ex`
encrypt/decrypt/verify rescue sites (narrow, typed 400, SHIM-COURT mirrors);
`eg_advanced_filters` + `event_grid` create-time validate!; `appconfig_features`
narrowed rescue with telemetry (ARMSTRONG fix 2); `eh_throttle` JA16-D3
typed-telemetry store-fault fallback; `partition_key.ex` total parse;
`resource_graph` typed InvalidParameter; `event_hubs.ex` serialized-server
CAS/lease path (lens-2/F-2 receipts in-line); `mhsm.ex` claim resolution and
unknown-condition fail-closed (F3 is the one hole); `table_storage`,
`sentinel`, `eh_schema_registry` ETS-heir idiom (SPOF-A covered).

## Top ticket (handoff to coordinator)

**EXPL-3-T1 (blob service-properties fail-open state mutation)** —
`set_delete_retention_policy`/`set_versioning_enabled` in
`lib/smalt/data_plane/blob_soft_delete.ex` admit garbage bodies with 200 and
mutate account state. Repair lane: three-case parse (empty=clear 200 /
envelope=parse / non-empty-envelope-absent=400 InvalidXmlDocument), plus a
shim-court proving the `<foo/>` PUT flips from 200-with-state-mutation to
typed 400 with prior policy preserved. F2/F3 dispatch as companion repair
lanes (queue TTL typed-400; MHSM empty-constraint-set refuse) — both carry
their own falsifiers above.
