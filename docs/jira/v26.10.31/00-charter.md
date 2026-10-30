# v26.10.31 Charter — Unification Dialect: Public-Cloud-Ontology Core

Consolidation lane 1 of 15, assembled 2026-10-30 from the landed v26.10.31 gap
lanes under `/Users/sac/smalt/docs/jira/posh/v26.10.31/` (gaps tree) and the
decision record. Every claim below cites its landed lane file; nothing is
restated from session memory.

## 1. Decision record (embedded)

Source: `posh/v26.10.31/00-unification-dialect-decision.md` (DECIDED, operator,
2026-10-30). smalt's core ontology becomes a **vendor-neutral public-cloud
ontology** (prior art first: OASIS TOSCA node types + DMTF CIMI semantics; scan
before minting classes). posh maps vendor dialects (Azure-ARM, Datadog, Stripe,
…) INTO that core; smalt never grows a per-vendor face. The current ARM face is
reclassified as **dialect #1 — the Azure shim, kept byte-identical** because the
wire-proven azurerm swap depends on it.

Laws carried forward (all witnessed in v26.10.30, per the decision record):

1. **One unification dialect**: vendors translate into smalt-core semantics;
   dialects live and die in posh.
2. **Ontology-gated admission**: new faces close via ontology ttl + regen
   (GraphLaw refuses ad-hoc routes); registry.ex is generated, never hand-edited.
3. **Receipts on every mutation** (turnstile fence, live on the ARM face);
   egress allowlist per target — posh.yaml is ceiling, graph is source.
4. **posh stays stateless and disposable** (SPAF Rule 1). Cautionary witness:
   the wave's one SPAF violation — `posh/internal/wasm` (arbitrary-byte
   admission, dead code; KILL verdict, `posh/v26.10.31/gaps/06-wasm-disposition.md`)
   — any posh component owning state or admission stops being a shim.

Carries over unchanged: GraphLaw admission mechanics, turnstile/receipt law,
egress fences, receipt formats, ggen projection discipline, courts (decision
record "What migrates vs carries over"). Migrates: api-version ceilings move
into the dialect layer (Azure vocabulary); the ARM face reclassifies from
native semantics to dialect #1. Additive path, no rewrite of wire-proven
surfaces: land smalt-core.ttl ABOVE existing registry families → grow dialect
#2 (first real consumer) → only then evaluate inverting the ARM face into posh.

## 2. Neutral core + two-layer admission

**Neutral core** (`smalt-core.ttl`, does not exist yet — census receipt
`posh/v26.10.31/gaps/02-payload-laws-census.md` status line confirms no
core ttl on disk): ontology-gated admission layer ABOVE the existing registry
families (containerApps, kv, storage, identity, RBAC, messaging), classes
derived FROM those families — a reclassification layer, not a rewrite
(lane 16 P1, `gaps/16-migration-sequencing.md`).

**Two-layer admission split** (`gaps/13-admission-split.md`, PARTIAL_ALIVE —
design landed, phases 1–3 UNEXECUTED):

- **LAYER 1 — core classes** are the GraphLaw admission authority, TOSCA-mapped:
  `ObjectRegistry`, `ContainerWorkload`, `ComputeEnvironment`, `SecretStore`,
  `DataStore`, `MessageHub`, `IdentityPrincipal`, `NetworkFabric`,
  `TrustAnchor`, `GovernanceSurface`. Generated as `lib/smalt/registry_core.ex`
  with a coverage assertion: every one of the 58 admitted types maps to exactly
  one core class (count(core-mapped types) == count(Registry.admitted_resource_types/0),
  else generation fails loudly).
- **LAYER 2 — dialect-type mappings** are GENERATED projections binding each
  `Microsoft.*` wire string to a core class (58 admitted + 4 inventory-only).
  Adding a second dialect must not touch LAYER 1 — the design's falsifier
  (gaps/13 H5 phase 3).
- Phase 1 derives core classes from existing TypeBinding families with
  ontology.ttl byte-identical; phase 2 splits `smalt-dialect-arm.ttl` out
  (set-equality court, no row lost, none invented); phase 3 flips
  `check_version/3` to core-admission-first ordering with a byte-identical
  wire-refusal shim-court across the full router corpus. Behavior-preservation
  gate across all phases: `admitted?/1`, `latest_version/1`,
  `admitted_version?/2` byte-identical for every input in the existing corpus.

**Credential model** (`gaps/09-credential-model.md`, PARTIAL — census ALIVE,
spec drafted, zero code changed; smalt @ f0e0a12, platform-az @ 31c58e9):

```
CredentialRequest :: {
  principal:   { kind: :client, id: PrincipalId }
  auth factor: { kind: :shared_secret, ref: SecretRef }
  audience:    Scope
}
Scope     :: :control_plane | {:data_plane, resource}
           | {:dialect, name, native_scope}
SecretRef :: {:env, name} | {:file, path} | {:literal, v}  // literal = dev only
```

- Azure's `https://management.azure.com/.default` is the azurerm-dialect
  *rendering* of core `:control_plane`; tenant is an opaque core key
  (`SMALT_TENANT_ID` canonical, `ARM_*` as dialect aliases); issuer is
  `config :smalt, :issuer_host` (already neutral, oidc_sts.ex Lane R9 comment).
- Per-dialect `DialectMapper` behaviour (3 callbacks: `to_wire`, `from_claim`,
  `scope_binding`); azurerm mapper reproduces today's wire byte-identically
  (recorded-corpus court). posh never mints — CC-4 grep court stays zero-hit
  (gaps/09 §2; gaps/16 P2).
- Phases: 1 = spec only (DONE, this file is the only write); 2 = dialect
  extraction (`Smalt.Cred.Core` + `Smalt.Cred.Dialect` behaviour, every P2
  consumer re-pointed, byte-identical STS court); 3 = face inversion, out of
  scope for v26.10.31 landing.

## 3. Dialect taxonomy

- **Dialect #0 — identity (STS)** (`gaps/01-sts-migration.md`, lane 1 verdict):
  the STS wire face (`POST /{tenant}/oauth2/v2.0/token`, Entra-shaped envelope,
  `aud`/`iss`/`tid`/`appid`/`azp`/`oid`/`roles` claims) classifies as
  **Azure-dialect, not sovereign** — preceding dialect #1. The in-memory token
  authority (StsGate AZB-15 DR gate, `Smalt.Auth.StsKey` RS256/HS256 custody,
  Bearer authority registry, sign-ins ring) is **sovereign and stays in smalt** —
  under law 4 a posh component owning token issuance would repeat the
  internal/wasm SPAF violation. STS = a sovereign in-memory credential
  authority with an Azure-dialect wire projection; the wire face stays
  byte-identical in smalt (wire-proven, azurerm-swap-depended-on), reclassified
  native → dialect projection.
- **Dialect #1 — Azure ARM/azurerm**: the existing ARM face, reclassified from
  native semantics to dialect; kept byte-identical (decision record).
- **Growth path**: dialect #2 = first real consumer by first admitted work
  order — Stripe if the billing consumer work order is admitted first, Datadog
  if the observability consumer is; "not by best-architecture argument — by
  first admitted work order" (gaps/16 P3). The shim lands in posh (stateless,
  disposable, law 4); a new-dialect court asserts dialect #2 resources resolve
  to core IRIs and NOT Azure IRIs. Second dialect must be addable as dialect
  TTL rows + one template pass with zero lib/smalt core edits — if a core class
  must change, the split has failed (gaps/13 H5 falsifier).

## 4. Migrates vs carries over (incl. the 14-law census)

**Carries over unchanged** (decision record): GraphLaw admission mechanics,
turnstile/receipt law, egress fences, receipt formats, ggen projection
discipline, courts.

**Reclassifies**: ARM face → dialect #1; STS face → dialect #0 (gaps/01);
api-version ceilings → dialect layer (decision record; census L6).

**14-law wire census** (`gaps/02-payload-laws-census.md`, ALIVE — every
current-home citation re-read from disk 2026-10-30; 7 neutral-core / 7
azurerm-dialect):

| # | Law | Class | Phase |
|---|-----|-------|-------|
| L2 | KV secret top-level location (generic envelope {name,type,location}) | NEUTRAL-CORE | P1 |
| L5 | secret-echo disjunction (value-or-etag-bump, never indistinguishable) | NEUTRAL-CORE | P1 |
| L7 | KV 201/200 create-vs-update status law (generic PUT created-vs-existed) | NEUTRAL-CORE | P1 |
| L8 | ARM LRO envelopes → neutral lifecycle vocab; render dialect til P3 | NEUTRAL-CORE | P1 |
| L10 | etag / If-Match optimistic concurrency (typed 409/412) | NEUTRAL-CORE | P1 |
| L11 | uuid5 deterministic mints (mech. core P1; GUID table dialect P2) | CORE + DIALECT | P1/P2 |
| L13 | tags full-replace + null-when-empty; locks 409 `ScopeLocked` | NEUTRAL-CORE | P1 |
| L1 | managedEnvironmentId dual-key emit/accept + import backfill | AZURE-DIALECT | P2 |
| L3 | numeric GiB memory coercion | AZURE-DIALECT | P2 |
| L4 | containerApps traffic-on-update-only (revision/traffic merge law) | AZURE-DIALECT | P2 |
| L6 | api-version ladders / monotonic ceilings (decision record explicit) | AZURE-DIALECT | P2 |
| L8b | Location-only (non-async) LRO variant — registered divergence only | AZURE-DIALECT | P2 |
| L9 | resourceGroups-casing tolerance (ARM id syntax is Azure vocabulary) | AZURE-DIALECT | P2 |
| L12 | 2023-06-preview day-less api-version normalization (pairs with L6) | AZURE-DIALECT | P2 |

**M14 turnstile digest — normative correction.** Per
`gaps/14-turnstile-neutrality.md` (Violations §1, "correction to the task
premise"): the cross-language contract is the **three-input** form

    BLAKE3(op_utf8 || u64BE(timestamp_ns) || payload_body)

— `settlement.ex:58-68`, `receipt_turnstile.ex:22-23`, `verify.go`; pinned
vector `0c39d201…db834`. NOT the four-input form (delta ∥ node_id ∥ ts ∥
state_root): the delta is the body; `node_id` and `state_root` are event-log
**entry fields**, not digest inputs. "Any charter text carrying the four-input
formula would be a false citation — use the three-input formula." The
turnstile receipt law is provider-neutral (no clause names a provider, Azure
resource type, or credential system); residual coupling is limited to the
`/subscriptions/*` route predicate (registered, gaps/14). The
`posh/internal/receipt/` Go BLAKE3 kernel is the F2b exception — KEEP, allowed
*because* byte-identical to the Elixir lane and holding no settlement authority
(gaps/17 F2b; gaps/06 inheritance clause).

**What must NOT migrate** (`gaps/17-what-must-not-migrate.md`, PARTIAL —
forbidden list normative-as-written, tripwires T2/T2b/T3/T4/T5 PLANNED, T1
partial via poshvet): F1 GraphLaw admission + ontology ttl; F2 turnstile/
receipt settlement + event log (F2b = the one pinned exception, the receipt
kernel); F3 store/ETS state + supervision trees; F4 ggen projection discipline
+ Turtle ontologies; F5 courts/receipts discipline; F6 registry.ex generation
path (`mix smalt.gen`); F7 ingress/egress turnstile supervision; F8 harness
substrate-state assertions (real HTTP vs the smalt plane, zero mocks).
Accretion test (the tripwire predicate): **any posh component that owns state
or admission stops being a shim**, detected by (1) arbitrary-byte/by-name
loading without sha256 pin + allowlist + handshake, (2) a persisted ledger,
(3) emitting pass/fail on admissibility, (4) a hand-edited projection.

**Fence disposition** (`gaps/05-fence-disposition.md`): egress fence is
single-homed per language runtime, not moved. Go (posh): `internal/egress` +
poshvet — PARTIAL, 7 live POSHVET-002 unfenced-client findings in-tree (fence
working, sites are the gap). TS: `scripts/hermetic_guard.sh` ALIVE, PASS exit
0. **BEAM side: MISSING** — `webpubsub/events.ex:101` (:httpc webhook) and
`data_plane/apim_gateway.ex:602-680` (Finch/:httpc forward) are unfenced
outbound dials; BEAM is the missing fence home. wazero: unguarded-but-surface-
free (WASI preview1 grants no sockets; no analyzer rule for guest modules).

**Harness coupling** (`gaps/11-harness-coupling.md`, ALIVE — 24 files / 3,022
lines classified): (a) DIALECT-CONFORMANCE 9 surfaces (tenant, container,
vault/lib+001+002, crmh live legs, version, siem/wire, shared client libs);
(b) CORE-BEHAVIOR 8 surfaces (vault-003 receipt fence, siem/audit-event,
ux-001 SLA, ux-002 diagnostics logic, nfr cleanup/concurrency/hermetic/perf);
(c) NEEDS-ABSTRACTION 0 (ontology-only core ruling). What changes: naming/
labels only, no assertion edits; `vault/tc-vault-003-receipt-header.test.ts`
must NOT be tagged dialect (it pins the core receipt fence);
`nfr/hermetic.test.ts`'s static endpoint guard is the one place with behavioral
blast radius under a dialect rename.

**Migration sequencing** (P0–P4, `gaps/16-migration-sequencing.md`), each
phase fenced by the **Byte-Identity Guard** (three legs: harness vitest
tenant+version suites exit 0; terraform 0-drift plan exit 0 (2=drift=FAIL,
1=error=FAIL); smalt-side tf_cleanroom STS POST legs + sha256 of oidc_sts.ex/
oidc_idp.ex unchanged):

- **P0** baseline freeze — record hashes (oidc_sts.ex, oidc_idp.ex, Go
  provider binary, dev_overrides block, plan exit 0) into
  `receipts/p0-baseline-freeze.md`; read-only, nothing to roll back. UNVERIFIED.
- **P1** smalt-core.ttl above existing families (lane 13 phase-1) — exit gate:
  guard + admission-corpus replay diff empty (frozen v26.10.30 witness set;
  any verdict flip = FAIL); rollback = delete smalt-core.ttl + regen.
- **P2** core/dialect pin split (M12) + credential model spec (M9, spec-only —
  ttl + regen receipt only, zero runtime change); CC-4 grep court
  `grep -r "JWT\|sign\|StsKey" posh/` zero mint-capable hits at every phase,
  any hit = REFUSED.
- **P3** dialect #2 (Stripe or Datadog by first admitted work order); new-
  dialect court (core IRIs, not Azure IRIs); guard re-run 0-drift after
  landing; rollback = delete the posh dialect package.
- **P4** ARM-face inversion evaluation only — no landing without an admitted
  work order; no landing in v26.10.31. UNSUPPORTED.

Input lane closure rule: a phase whose input lanes are still open is BLOCKED,
not failed; sequence does not skip ahead.

## 5. Doc-migration ledger

Per `gaps/15-doc-migration-plan.md` (census ALIVE, edits UNVERIFIED — wave-2
work owned per-row; every row carries its own close condition):

- **Tier A — gains a NEUTRAL-CORE section in v26.10.31**:
  `dfcharter/charter-master.md` (new "Neutral core (v26.10.31)" section:
  Port In = dialect-facing ingress, Starboard = smalt-core-facing egress,
  turnstile = mutation-receipt fence, dialect = vendor translation layer in
  posh); `requirements-synthesized.md` (new "Dialect layer" section: Go
  adapter shims reclassify as dialect faces; ARM = dialect #1, STS = #0);
  `glossary.md` (prepend NEUTRAL-CORE block; Azure table becomes the
  dialect-#1 sub-glossary); `README.md` v26.10.30 (POSH section header cross-ref;
  POSH-003/004 rows marked DIALECT-SCOPED).
- **Tier B — DIALECT-SCOPED stamps**: `working-backwards.md` (additive
  "Dialect scoping note"; operator text stays verbatim),
  `gaps/01-provider-azurerm-parity.md` (G1 azurerm_role_definition
  UNSUPPORTED is dialect-#1-scoped), POSH-003, POSH-004, POSH-009
  (one-line stamp: parity target is the dialect-#1 surface). POSH-005/006/008
  are NOT Tier B — membrane-level, Tier C.
- **Tier C — unchanged**: triz.md, exit-codes.md, POSH-001/002/005/006/008/010,
  dfcharter DMADV process docs, schema-v1.md (already the dialect-#1 schema of
  record).
- **Cross-ref obligations**: decision record backlinked from v26.10.30 README
  POSH section, requirements-synthesized.md, POSH-004 — <3 mandatory backlinks
  = FAIL; anti-vacuity mutation (remove one Tier B stamp in a temp copy) must
  flip the court to FAIL.

## 6. Open questions (decision record's three)

1. **TOSCA/CIMI coverage scan**: do smalt's registry families (containerApps,
   kv, storage, identity, RBAC, messaging) map 1:1 onto TOSCA node types, or
   do Azure-specific shapes (LRO envelopes, api-version ladders) need a
   core-level equivalent (e.g. neutral lifecycle/versions vocabulary)? Close
   condition: the scan lands as a core-vocabulary decision feeding P1's L8
   neutral lifecycle vocabulary (census L8 names it "the gating design item"
   for P3). Feeds: lanes 9, 13, 16.
2. **Wire face vs ontology-only core**: does the neutral core need its own
   wire face, or is the core admission/ontology-only with dialect faces
   staying wire-shaped? (Receipts favor ontology-only first — decision record;
   gaps/11 proceeds from the ontology-only ruling; category (c)
   NEEDS-ABSTRACTION is empty under it.) Close condition: a typed ruling
   recorded in this charter before P3; if core-wire-face is chosen, the
   gaps/11 (a) list converts to (c) with `lib/smalt-client.ts` as the
   abstraction seam.
3. **Identity semantics**: Entra/SAML shapes are Azure-flavored — the neutral
   core needs a principal/credential model before the first non-Azure dialect.
   gaps/09 supplies the spec (CredentialRequest/Scope/SecretRef, §2 above);
   close condition per gaps/16 P2: CC-3 mapping court — STS claims set maps
   onto the core classes 1:1, spec-only, zero runtime change in P2.

## 7. Lane lease table (v26.10.31)

Canonical checkout `/Users/sac/smalt`, one tree, no worktrees; coordinator
owns git transitions; lanes hold disjoint file leases (shape per
`posh/v26.10.30/_LANES.md`). Gap files: `posh/v26.10.31/gaps/`.

| lane | gap file | subject | lease |
|---|---|---|---|
| 1 | gaps/01-sts-migration.md | STS face class (dialect #0; CC-1..4) | STS surfaces read-only |
| 2 | gaps/02-payload-laws-census.md | 14-law wire census (7 core / 7 dialect) | gaps/02 write |
| 3 | gaps/03-provider-mapping-inventory.md | provider mapping: shim vs generic-client | gaps/03 |
| 4 | gaps/04-diagnostic-vocabulary.md | diagnostic vocabulary | gaps/04 write |
| 5 | gaps/05-fence-disposition.md | egress fence per-runtime single-homing | gaps/05 write |
| 6 | gaps/06-wasm-disposition.md | internal/wasm KILL + named inheritance | gaps/06 write |
| 7 | gaps/07-tui-watcher-seams.md | TUI telemetry + watcher seams | gaps/07 write |
| 8 | gaps/08-k8s-coupling.md | k8s-facing logic census | gaps/08 write |
| 9 | gaps/09-credential-model.md | neutral credential model + dialect extraction census | gaps/09 |
| 10 | gaps/10-spike-residuals.md | spike residuals | gaps/10 |
| 11 | gaps/11-harness-coupling.md | harness per-suite dialect classification | gaps/11 |
| 12 | gaps/12-compat-pin-split.md | compat pin split (M12) | gaps/12 |
| 13 | gaps/13-admission-split.md | two-layer admission split (M13) | gaps/13 |
| 14 | gaps/14-turnstile-neutrality.md | turnstile neutrality + digest fix | gaps/14 |
| 15 | gaps/15-doc-migration-plan.md | doc migration Tier A/B/C plan | gaps/15 |
| 16 | gaps/16-migration-sequencing.md | P0–P4 sequencing + Byte-Identity Guard | gaps/16 |
| 17 | gaps/17-what-must-not-migrate.md | SOVEREIGN forbidden list F1–F8 + tripwires | gaps/17 |
| — | gaps/69-dod-execution-harness.md | DoD harness pattern (v26.10.30) | read-only |
| consolidation | this file | 00-charter.md assembly | 00-charter.md |

## 8. DoD shape (per the gaps/69 pattern)

Per `posh/v26.10.31/gaps/69-dod-execution-harness.md` (v26.10.30 lane-16
verdict: 4 PASS / 2 FAIL / 14 PLANNED, exit 1, wave NOT DONE — real executed
commands over narration): the v26.10.31 DoD is an executed harness, not a
checklist. Its shape:

1. **Machine-checked rows probing disk at run time** (Chicago: real
   execution, no mocked gates). The v26.10.30 residual: HRN-013's row reported
   PLANNED via a hardcoded planned_reason while `scripts/harness_mutation_court.sh`
   existed on disk — row probes must read disk, not metadata
   (gaps/69 Residual #1).
2. **Exit contract**: any FAIL row forces exit 1; never-fake law — PLANNED
   rows reported as PLANNED, never rounded to PASS (gaps/69: 14 PLANNED rows
   reported as PLANNED).
3. **Typed SKIP, loud**: substrate down ⇒ exit 3; KPI-3 flake witness loud-skips
   ("no suites to loop") until suites land, never silently passes (gaps/69
   Residual #5).
4. **Per-lane close rows** for this wave: P0 receipt exists
   (`receipts/p0-baseline-freeze.md`); Byte-Identity Guard three legs pass at
   every phase; admission-corpus replay diff empty (P1); CC-4 grep court
   zero-hit (P2); new-dialect court core-IRI resolution + 0-drift guard (P3);
   doc-migration cross-ref court ≥3 backlinks + anti-vacuity flip (§5);
   gaps/17 tripwires T2/T2b/T3 wired (a tripwire that cannot flip is FAIL per
   shim-court non-vacuity law).
5. **Verdict vocabulary**: ALIVE (ran, command + exit) / PARTIAL / BLOCKED
   (cite file:line) / REFUSED / UNVERIFIED (default) — never claim planned/
   inspected work as executed.

## Status line

- Decision record: ALIVE (DECIDED, operator 2026-10-30, on disk at
  `posh/v26.10.31/00-unification-dialect-decision.md`).
- Lanes 1–17 gap files: ALIVE on disk under `posh/v26.10.31/gaps/` (statuses
  per file: 01 closed per gaps/16 cross-reference; 02 ALIVE; 05 ALIVE; 06
  PARTIAL_ALIVE; 09 PARTIAL; 11 ALIVE; 13 PARTIAL_ALIVE; 15 ALIVE-plan/edits
  UNVERIFIED; 16 ALIVE-spec/legs UNEXECUTED; 17 PARTIAL).
- P0–P3: UNVERIFIED; P4: UNSUPPORTED (no admitted work order).
- Byte-Identity Guard: ALIVE as specification, not executed this session.
- This charter file: **ALIVE** (written this session, this Write, exit 0).
