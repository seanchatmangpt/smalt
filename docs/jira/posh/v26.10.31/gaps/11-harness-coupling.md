# 11 Harness Dialect Coupling — Per-Suite Classification

Status: **ALIVE** — classification executed this session over every file in
`/Users/sac/cai/courtroom-platform-az/apps/web/test/harness/**` (3,022 lines
across 24 files, read in full or by targeted line-range; no suite classified
from its name alone).

## Framing

The lane dispatch carries the dialect decision: ontology-only core (decision
record open question 2 resolved toward ontology-only). Under that ruling,
category (c) NEEDS-ABSTRACTION is empty today — no dialect-abstraction layer
exists, so suites asserting dialect payloads remain **(a)
DIALECT-CONFORMANCE**. The decision record itself is not in this repo
(no file under docs/, gaps/, receipts/, or v26.10.31/ names "dialect",
"azurerm dialect", "ontology-only", or an open-question block); this lane
proceeds from the ruling as stated in the dispatch prompt. If a canonical
record lands elsewhere, its open-question-2 wording governs.

## Classification

Key: (a) = DIALECT-CONFORMANCE, (b) = CORE-BEHAVIOR, (a|b) = mixed suite
with (b) legs to preserve untouched.

| Suite (under `apps/web/test/harness/`) | Class | Asserts (evidence) | What changes |
|---|---|---|---|
| `tenant/tenant.test.ts` | (a) | ARM resourcegroups@2023-07-01 PUT/GET/DELETE roundtrip; roleAssignments@2022-04-01 foreign-scope admission (registered divergence, honestly witnessed); Key Vault secret shape 400 fail-closed law | naming/labels only |
| `container/container.test.ts` | (a) | `Microsoft.App` managedEnvironments + containerApps @2023-05-01; `managedEnvironmentId` payload key; numeric GiB memory | naming/labels only |
| `vault/lib.ts` + `vault/tc-vault-001-retrieval.test.ts` | (a) | ARM Key Vault secret URL shape, api-version, typed 404 `ResourceNotFound` body, disjunctive value retrieval | naming/labels only |
| `vault/tc-vault-002-fail-closed.test.ts` | (a) | 404 `ResourceNotFound` typed Azure error body via ARM secret URL; typed MissingSecretError contract | naming/labels only |
| `vault/tc-vault-003-receipt-header.test.ts` | (b) | X-Smalt-Receipt-Turnstile fence (64-hex digest) required on mutating verbs — this is the smalt plane's own receipt law, not an ARM construct; the fence is core (cf. lane 14's turnstile-neutrality finding) | survives dialect migration untouched |
| `crmh/crmh.test.ts` + `crmh/lib.ts` | (a\|b) | offline legs: blobPath schema law `crmh/daily-exports/{tenantId}/{timestamp}.json` (repo-side law, substrate-independent) = (b); live legs: ARM storage data-plane probe = (a) | keep (b) legs untouched; (a) legs rename when dialect layer formalizes |
| `version/` (`version.test.ts`, `lib.ts`) | (a) | the suite's entire subject IS the dialect: CEILINGS table, api-version ladder (2022-03-01 and 2023-05-01 both admitted), out-of-ceiling 400 `InvalidApiVersionParameter` naming latest supported, registries@2023-07-01 registered divergence, `SmaltVersionError` remediation contract | keep as dialect-conformance; rename/scope when the dialect layer formalizes |
| `siem/wire.test.ts` | (a) | real HTTP/AMQP wire legs against the plane; ARM RG cascade cleanup | naming/labels only |
| `siem/audit-event.test.ts` | (b) | offline auditEvent builder + receipt digest pairing; zero wire | survives untouched |
| `ux/tc-ux-001-sla.test.ts` + `ux/lib.ts` | (b) | fetchWithSla SLA ergonomics against a REAL local HTTP server (node http.createServer, real socket, real timeout); typed SmaltTimeoutError with process alive; happy path real plane | survives untouched |
| `ux/tc-ux-002-diagnostics.test.ts` | (b), dialect-pinned fixtures | formatSubstrateError logic is core; fixtures are REAL captured smalt refusal bodies whose field vocabulary (`error.code/message/target/details`) is dialect wire shape | core logic survives; fixtures re-capture if the dialect changes |
| `nfr/cleanup.test.ts` + `lib/residue.ts` | (b) | residue registry determinism, sweep-under-failure, real subscription GET asserting empty h10-* residue | survives untouched (ARM wire is transport here, not the subject) |
| `nfr/concurrency.test.ts` + `lib/concurrency.ts` | (b) | concurrent armWithRetry ergonomics over real plane | survives untouched |
| `nfr/hermetic.test.ts` | (b) | egress fail-fast via real OS subprocess fetches + static guard against hard-coded public Azure endpoints (scripts/hermetic_guard.sh) | survives untouched; note the static guard's endpoint literals are dialect-coupled and get revisited if the dialect layer lands |
| `nfr/perf.test.ts` | (b) | loopback roundtrip latency fences + mintTokenCached hit path, honest colima-hop transport caveat, SMALT_NFR_STRICT promotion | survives untouched |
| `lib/smalt-client.ts`, `lib.ts`, `setup.ts` | (a) shared client | speak ARM paths/api-versions/tokens on behalf of all suites | the natural seam if a dialect-abstraction layer is ever built (open question 2's (c) lives here, not in the suites) |

## Tally

- (a) DIALECT-CONFORMANCE: 9 surfaces — tenant, container, vault/lib+001,
  vault-002, crmh live legs, version, siem/wire, shared client libs.
- (b) CORE-BEHAVIOR: 8 surfaces — vault-003 (receipt fence), siem/audit-event
  (offline), ux-001 (SLA), ux-002 (diagnostics logic), nfr/cleanup (residue),
  nfr/concurrency, nfr/hermetic, nfr/perf; plus crmh offline schema-law legs.
- (c) NEEDS-ABSTRACTION: 0 suites, per the ontology-only-core ruling. If the
  core later grows its own wire face, the (a) list converts to (c) with
  `lib/smalt-client.ts` as the abstraction seam; nothing else restructures.

## What changes (verdict)

Under ontology-only core: **naming/labels only**. No suite moves, no test
logic changes, no abstraction layer is built. Concretely:

1. `version/` is already dialect-conformance in substance; when the dialect
   layer formalizes, rescope its describe-block labels (e.g. "azurerm
   dialect ceilings") — no assertion edits.
2. The (a) suites' describe-block labels may gain an explicit
   "dialect-conformance" tag; assertion bodies stay byte-identical.
3. `vault/tc-vault-003-receipt-header.test.ts` must NOT be tagged
   dialect-conformance — it pins the core receipt fence and survives the
   dialect migration untouched.
4. `nfr/hermetic.test.ts`'s static endpoint guard is the one place where a
   dialect rename has behavioral blast radius; flag for the dialect-layer
   lane when it exists.

## Status

ALIVE — read-only classification; the only write this session is this file.
No changes to `apps/web/` or `apps/web/test/`.