# FINAL — v26.10.31 Manufacturing Receipt

Window goal: formalize smalt's core ontology as a vendor-neutral public-cloud ontology
(TOSCA node types + DMTF CIMI semantics), reclassify Azure-ARM as Dialect #1, and
establish the two-layer admission authority model.

- subject: smalt @ `43e68a45` (`43e68a45ed5e0dc32a24d74dc9206f1306a21bf8`)
- version: `26.10.31` (`mix.exs @version "26.10.31"`)
- date: 2026-10-30
- standing: **ALIVE** — core ontology validated with 0 proprietary IRIs and 9 closed shapes; provider import suite PASS; POSH Go suite PASS.

## Landed Capabilities

| item | receipt / evidence | standing |
|---|---|---|
| Vendor-neutral Public Cloud Core Ontology | `priv/ontologies/public-cloud-core.ttl` (318 triples, 9 shapes) | ALIVE |
| Closed-World Admission Court | `scripts/verify_public_cloud_ontology.py` (exit 0) | ALIVE |
| Unification Dialect Decision | `docs/jira/posh/v26.10.31/00-unification-dialect-decision.md` | DECIDED |
| Core Credential Model & Scope Abstraction | `docs/jira/v26.10.31/gaps/09-credential-core-model.md` | ALIVE |
| Two-Layer Admission Split Architecture | `docs/jira/posh/v26.10.31/gaps/13-admission-split.md` | ALIVE |
| Provider Import-State & Turnstile Suite | `adapters/terraform-provider-smalt/internal/provider/` (12 blocks PASS) | ALIVE |
| Consolidated Definition of Done | `docs/jira/v26.10.31/gaps/09-dod-consolidated.md` | ALIVE |
| Gap Analysis & Migration Sequencing (M1–M17) | `docs/jira/posh/v26.10.31/gaps/` | ALIVE |

## Verification Ladder

1. **Public Cloud Ontology Court**:
   `python3 scripts/verify_public_cloud_ontology.py` → `VERDICT: ALIVE [GREEN] (public-cloud-core.ttl fully admitted)` (exit 0).
2. **POSH Go Membrane**:
   `cd posh && go test ./...` → All packages ok / cached, 0 errors (exit 0).
3. **Provider Core & Live Suite**:
   `cd adapters/terraform-provider-smalt && go test ./...` → `ok terraform-provider-smalt/internal/provider` (exit 0).
4. **Provider Import Gate**:
   `python3 scripts/dod_check.py --section import` → `PASS POSH-004-IMPORT` (exit 0).
5. **Receipts Index Discoverability**:
   `bash scripts/receipts_index.sh` → Runs cleanly across all repository surfaces (exit 0).
