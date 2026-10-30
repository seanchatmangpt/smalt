# GAP-15: Documentation migration plan — dialect decision rollout (v26.10.31)

Lane 15 of 17, unification-dialect migration. Anchor:
`../00-unification-dialect-decision.md` (DECIDED, operator, 2026-10-30).
This is a plan lane: it censuses the normative corpus
(`docs/jira/posh/v26.10.30/` + `dfcharter/*`), classifies each doc as
(a) gains a NEUTRAL-CORE section in v26.10.31, (b) becomes DIALECT-SCOPED
azurerm-swap documentation, or (c) unchanged (dialect-independent already).
No prose below is executed migration — each row carries its own close
condition; the doc edits are wave-2 work owned per-row.

## Corpus census and classification

Core law being propagated: smalt-core = vendor-neutral public-cloud ontology
(TOSCA/CIMI prior art first); vendor dialects (Azure-ARM, identity/Entra,
Datadog, Stripe) live in posh; the current ARM face is dialect #1, the Entra
STS wire face is dialect #0 (verdict per `gaps/01-sts-migration.md`, lane 1).

### Tier A — gains a NEUTRAL-CORE section in v26.10.31

| Doc (all under `v26.10.30/` unless noted) | Dialect coupling witnessed | Planned v26.10.31 edit |
|---|---|---|
| `dfcharter/charter-master.md` | Terms (Port In, Starboard, turnstile, dialect) exist only in v26.10.30 vocabulary where "the substrate" = smalt-as-Azure-emulator; no neutral definitions anywhere in the corpus. | New section "Neutral core (v26.10.31)": define Port In = the dialect-facing ingress of the membrane; Starboard = smalt-core-facing egress; turnstile = mutation-receipt fence; dialect = a vendor translation layer living in posh. Terms get core IRIs in smalt-core.ttl when it lands (lanes 9/13 feed). |
| `requirements-synthesized.md` | "Architecture requirement (settled)" declares the tri-tier POSH membrane with the Go adapter hosting "Azure/K8s protocol shims" — vendor-coupled phrasing; no dialect concept exists in it. | New section "Dialect layer (v26.10.31)": the Go adapter's shims reclassify as dialect faces; neutral-core admission layer sits above registry families; cross-ref `../v26.10.31/00-unification-dialect-decision.md`; reclassify ARM = dialect #1, STS = dialect #0. |
| `glossary.md` | Entirely smalt-as-Azure-emulator vocabulary; the bilingual table maps charter terms to Azure-emulation code artifacts. | Prepend a NEUTRAL-CORE block defining Port In, Starboard, turnstile, dialect, dialect #0 (identity), dialect #1 (Azure ARM), smalt-core.ttl; keep the existing Azure table as the dialect-#1 sub-glossary under a renamed heading, not the whole glossary. |
| `README.md` (v26.10.30) | POSH section presents the azurerm swap as the product ("wire-accurate Azure ARM emulation") — dialect-as-core conflation at the doc entry point. | POSH section gains a header cross-ref: "Dialect decision: `../v26.10.31/00-unification-dialect-decision.md` — the azurerm swap is dialect #1, not the core"; POSH-003/004 rows marked DIALECT-SCOPED. |

### Tier B — becomes DIALECT-SCOPED (azurerm-swap) documentation

| Doc | Azure-specific content witnessed | Planned v26.10.31 edit |
|---|---|---|
| `working-backwards.md` (62 lines, read on disk) | Codename "Smalt-PISO (Sovereign Azure Substrate…)", GA announcement = "wire-accurate Azure ARM emulation … unmodified azurerm Terraform stacks", terraform apply < 2s claim, STS = "mirroring Azure AD v2.0 endpoints". | Additive "Dialect scoping note (v26.10.31)" header block stating the press-release claims are dialect-#1-scoped (azurerm swap) and dialect-#0-scoped (Entra STS). The operator-supplied text stays verbatim — core-level equivalents are v26.10.31 charter items, never edits to operator text. |
| `gaps/01-provider-azurerm-parity.md` | G1: `azurerm_role_definition` fully UNSUPPORTED — an azurerm-schema gap, dialect-#1-scoped by construction. | Stamp "DIALECT-SCOPED: dialect #1 (Azure ARM/azurerm)". Close condition stays azurerm-scoped; a neutral-core row for role definition gets a forward pointer, not a fix here. |
| `POSH-003-azure-arm-client.md` | Whole ticket is the Azure ARM face (azidentity, ARM SDK, STS mint at the Entra-shaped endpoint, ARM_METADATA_HOSTNAME env contract). | Stamp DIALECT-SCOPED (dialect #1, consumes dialect #0 STS) + header cross-ref to the decision record. |
| `POSH-004-terraform-provider-go.md` | azurerm resource set + schema parity, dev_overrides byte-identical swap, schema-v1.md resource list. | Stamp DIALECT-SCOPED (dialect #1) + header cross-ref to the decision record (task-mandated). Stamps are additive; acceptance criteria stay byte-identical in meaning. |
| `POSH-009-sdk-parity-register.md` | Parity target stated as "vs the real Azure surface smalt emulates". | One-line stamp: parity target is "the dialect-#1 surface"; gate semantics unchanged. |

Not Tier B despite Azure-adjacent text: POSH-005 (packaging), POSH-006
(courts), POSH-008 (fences) — their acceptance criteria name no vendor
surface; they are membrane-level (Tier C). `schema-v1.md` is already wholly
azurerm-swap-scoped by construction — it IS dialect documentation; no stamp
needed, listed unchanged.

### Tier C — unchanged (dialect-independent already)

| Doc | Basis |
|---|---|
| `dfcharter/triz.md` | Operator-supplied, authoritative; contradiction matrix is membrane-level (Principle 24 intermediary); no vendor surface in its laws (1 "Azure" mention, grep -c = 1). |
| `exit-codes.md` | Per-script-family PASS/FAIL/SKIP matrix; court mechanics, vendor-free. |
| POSH-001, POSH-002, POSH-005, POSH-006, POSH-008, POSH-010 | Scaffold, membrane protocol, packaging, courts, fences, wave plan — membrane-level, vendor-free acceptance criteria. POSH-008's allowlist (posh.yaml) is the ceiling in decision-record law 3; nothing Azure-named. |
| `dfcharter/` process docs (define/measure/analyze/design/verify/andon/dpmo/raci-signoff) | DMADV process records; vendor-free. |
| `schema-v1.md` | Already the dialect-#1 schema of record; wholly swap-scoped by construction — no edit. |

## Cross-reference obligations

`../00-unification-dialect-decision.md` must be cross-referenced from
(grep receipts at close time):

1. `v26.10.30/README.md` POSH section — entry-point pointer, POSH-003/004 stamped.
2. `requirements-synthesized.md` — inside its new Dialect layer section.
3. `POSH-004-terraform-provider-go.md` — header stamp.
4. Corpus-wide close-time court: greps for `00-unification-dialect-decision`
   backlinks, asserts the three mandatory locations plus no un-stamped Tier B
   doc (a Tier B doc without a stamp fails the gate; exit 1).

### Cross-ref court (non-vacuity)

- < 3 mandatory backlinks ⇒ FAIL.
- Anti-vacuity mutation: remove one Tier B stamp in a temp copy; the court must
  flip to FAIL (a court that cannot flip is FAIL).
- Read-only + temp copy; never writes the corpus.

## Charter skeleton outline (v26.10.31)

Target file: `v26.10.31/00-charter.md` (does not exist yet; lanes feed it).
Tier ordering = decision-record laws 1–4 applied to prose.

1. **Decision record embedding** — the 4 laws from
   `00-unification-dialect-decision.md`; cite the v26.10.30 evidence base.
   Feeds: the decision record itself (landed; no lane).
2. **Neutral core definition** — smalt-core.ttl: ontology-gated admission
   above registry families; api-version ceilings reclassify to the dialect
   layer. Feeds: lane 13 (admission split), lane 16 (migration sequencing),
   lane 9 (principal/credential classes → core classes; gaps/01 CC-3).
3. **Dialect taxonomy** — dialect #0 identity, dialect #1 Azure ARM, growth
   path (first non-Azure consumer per charter consumer list: Stripe or
   Datadog). Feeds: lane 1 (STS = dialect #0 verdict), lane 8 (k8s coupling),
   lane 12 (compat-pin split).
4. **What migrates vs carries over** — carries-over (GraphLaw admission
   mechanics, turnstile/receipt law, egress fences, receipt formats, ggen
   projection discipline, courts) vs migrates (api-version ceilings → dialect
   layer, ARM-face reclassification). Feeds: lane 17 (what must not migrate),
   lane 16 (sequencing), lane 5 (fence disposition), lane 6 (wasm
   disposition), lane 11 (harness coupling).
5. **Doc-migration ledger** — this file's Tier A/B/C table, executed.
   Feeds: lane 15 (this lane).
6. **Open questions** — the three decision-record open questions (TOSCA/CIMI
   1:1 mapping; wire face vs ontology-only core; neutral
   principal/credential model) restated as charter items with close
   conditions. Feeds: lanes 9, 13, 16.
7. **Lane lease table** — v26.10.31 window leases, reusing the
   `v26.10.30/_LANES.md` shape. Feeds: coordinator.
8. **DoD / close conditions** — reusing the `gaps/69-dod-execution-harness.md`
   shape (present in both windows' gaps trees). Feeds: gaps/69 in the
   v26.10.31 gaps tree.

## Status

- Corpus census: **ALIVE** — every doc named above read or header-read with
  line counts from disk this session (2026-10-30).
- Classification (Tier A/B/C) + charter skeleton: **ALIVE** — produced this
  session, grounded in the census.
- Executed doc edits (Tier A sections, Tier B stamps, cross-ref court):
  **UNVERIFIED** — wave-2 work; no corpus file was modified by this lane.
- Decision record: **ALIVE** (DECIDED, 2026-10-30, on disk).
