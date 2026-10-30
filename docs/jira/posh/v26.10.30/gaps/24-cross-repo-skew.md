# 24 Cross-Repo Skew: courtroom-platform-az vs smalt (POSH provider)

Status: PARTIAL (read-only census 2026-10-30; every cell re-read from disk this
session — no executable cross-repo court ran, that is GAP5(b) by design).

Subjects:

- consumer: `/Users/sac/cai/courtroom-platform-az` (this repo, HEAD 31c58e9)
- substrate: `/Users/sac/smalt` (adapters/terraform-provider-smalt @ working tree)

No compatibility pin exists between the two trees: courtroom's
`infra/**/versions.tf` pins only `azurerm ~> 5.12` + `terraform >= 1.9`, and
smalt's provider carries `version = "dev"` with no release channel. Every row
below is therefore **unpinned** and can skew silently on either side.

## Per-type api-version matrix (provider wire vs smalt registry top)

Provider api-version constants read from
`smalt/adapters/terraform-provider-smalt/internal/provider/{arm_client,resource_*}.go`;
smalt tops from `smalt/lib/smalt/registry.ex` `@api_versions`. Verdicts use the
smalt admission lattice (monotonic, half-open `(-inf, top]`, `registry.ex:210-220`).

| Resource | Provider sends | smalt top | Verdict |
|---|---|---|---|
| resource group | 2023-07-01 | 2023-07-01 | aligned |
| container app | **2024-03-01** (fallback 2023-05-01) | 2023-05-01 | skewed, self-healing |
| container app environment | **2024-03-01** (fallback 2023-05-01) | 2023-05-01 | skewed, self-healing |
| key vault (+ secrets) | 2023-07-01 (fallback 2023-02-01) | 2023-07-01 | aligned (fallback ≤ top) |
| user-assigned identity | 2023-04-01 | 2023-04-01 | aligned |
| federated identity credential | 2023-01-31 | 2023-08-01 | aligned (≤ top) |
| container registry | **2023-07-01, NO fallback** | 2023-06-01 | **skewed — refusable** |
| log analytics workspace | 2022-10-01 | 2022-10-01 | aligned |
| storage account | 2023-01-01 | 2023-05-01 | aligned (≤ top) |
| role assignment | 2022-04-01 | 2022-04-01 | aligned |
| role definition | 2022-04-01 | (absent from registry) | skewed — UNSUPPORTED (see below) |

Notes on the two skewed cells:

- container app / CAE: provider leads with `2024-03-01`, eats
  `InvalidApiVersionParameter` 400, retries at `2023-05-01`
  (`resource_container_app.go:640-673`). Works, but the first PUT of every
  create/update pays a wasted round-trip and the coupling survives only via the
  fallback ladder — a compat pin file would make this visible.
- container registry: `acrAPIVersion = 2023-07-01`
  (`resource_remaining_v1.go:1588`) with **no** InvalidApiVersion fallback —
  smalt top is 2023-06-01, so every ACR PUT/GET/DELETE is a 400
  `InvalidApiVersionParameter` on the current smalt tree (provider constant
  > smalt top = refusable today). Close = either provider drops to
  ≤ 2023-06-01 or smalt raises the top; register in the compat pin either way.
- role definition: smalt registry has no
  `Microsoft.Authorization/roleDefinitions` row; provider registers
  `RoleDefinitionResource` with loud-partial semantics
  (`resource_remaining_v1.go:82-83`), and courtroom `access/main.tf:134`
  actually instantiates `azurerm_role_definition` (feeding the plan identity's
  role assignment at :159). Matches the KNOWN gap
  `~/smalt/docs/jira/posh/v26.10.30/gaps/01-provider-azurerm-parity.md` /
  `07-secrets-identity.md` — listed here as the consumer-side witness, not
  re-diagnosed.

## Payload-shape assumptions (provider translation vs smalt validation)

All shapes verified against `smalt/lib/smalt/arm_gateway/providers/container_apps.ex`.

| Assumption | Provider behavior | smalt expectation | Verdict |
|---|---|---|---|
| `managedEnvironmentId` | sets both `managedEnvironmentId` and `environmentId` (`resource_container_app.go:1014-1015`); import backfills from response (`:1292`) | validates env row exists; typed 400 `EnvironmentNotFound` (`container_apps.ex:767-782`) | aligned (fail-closed both sides) |
| memory units | sends string `"1Gi"`; on 400 `resources.memory` retries with `parseMemoryGiB` numeric coercion (`resource_container_app.go:606-641`) | requires `is_number(memory)` (`container_apps.ex:1141-1151`) | skewed, self-healing (one wasted PUT per memory-bearing create) |
| top-level `location` | always sets `body["location"]` (`resource_container_app.go:697`, CAE :278); defaults to `eastus` when empty | echoes `body["location"]` into the store row; ARM shape requires it | aligned |
| traffic on update | writes `configuration.ingress.traffic` with `weight`/`latestRevision`/`latestRevisionName` (`:1104-1120`); Update merges existing config first (`:1032-1038`) | requires entries bind real revisions, sum 100, single latest (`container_apps.ex:1023-1061`); Single-mode platform act handles retire | aligned |

## Cluster name / kind lane

- smalt kind-config pins `name: smalt` (`smalt/k8s/kind-config.yaml:19`);
  `kind load docker-image smalt:local --name smalt` is hardwired in
  `smalt/k8s/README.md:39` and the posh-court pre-stage
  (`justfile.d/58-posh.just:288` `SMALT_KIND_BACKEND_IMG=smalt:local`).
- Consumer docs (courtroom README "Local development via smalt (POSH)",
  README.md:110-125) say only "a kind cluster" — never name it. A consumer who
  follows courtroom docs alone will `kind create` an arbitrarily named cluster
  and the posh pre-stage's `--name smalt` load will target/miss the wrong one.
- Verdict: **skewed-by-omission** (unpinned, doc-level). Close: one line in
  courtroom README naming cluster `smalt` + a compat pin row.

## Image tags (note only, kind-lane-unrelated)

`deploy-dev.yml:48-54` builds and pushes
`$REGISTRY/courtroom-$app:$COMMIT_SHA` and records the ACR repo-digest
(`RepoDigests[0]`) — ACR SHA tags. This couples courtroom to its own ACR, not
to the smalt kind lane (`smalt:local`). No smalt coupling in this row;
recorded for completeness.

## Terraform / provider version expectations

| Coupling | Consumer | Substrate | Verdict |
|---|---|---|---|
| Terraform CLI | `>= 1.9.0, < 2.0.0` (all three versions.tf) | posh path needs >= 1.14 (attribute-form dev_overrides; labeled form rejected) | **unpinned/skewed at the edges** — 1.9–1.13 satisfies courtroom but breaks the posh path |
| azurerm provider version | `~> 5.12` required constraint in HCL | dev_overrides bypasses version selection entirely; provider reports `version = "dev"` | unpinned by construction (dev_overrides) — the HCL pin is inert on the smalt path |

## dev_overrides rc files (two writers, both live)

| rc path | Writer | State on disk (2026-10-30) |
|---|---|---|
| `smalt/adapters/terraform-provider-smalt/dev.tfrc` | `scripts/dev_overrides.sh` (via `make install`) | live, mtime Oct 30 12:08, `direct {}` |
| `smalt/tmp/posh/tfrc` | `justfile.d/58-posh.just` posh-install (printf writer, :212-220) | live, mtime Oct 30 10:54, `direct { exclude = ["hashicorp/azurerm"] }` |

Both are alive and point at the same module dir; they agree on the
dev_overrides mapping (attribute form, `hashicorp/azurerm` → provider module
dir). Cosmetic divergence: `direct {}` vs `direct { exclude = [...] }` — no
functional difference under dev_overrides (the override wins regardless).
Two idempotent writers for one concept is O(N²) drift surface (dfcm law);
close condition folds posh-install to call `scripts/dev_overrides.sh` (or the
pin file) as the single writer.

## Coupling matrix summary + skew rows

| # | Coupling | Verdict | Close condition |
|---|---|---|---|
| S1 | ACR api-version 2023-07-01 vs top 2023-06-01, no fallback | **skewed — refusable today** | provider constant ≤ 2023-06-01 OR smalt raises top; compat pin row updated by whichever side moves |
| S2 | role definition: instantiated by courtroom, unregistered in smalt registry | **skewed — UNSUPPORTED** | already tracked in smalt gap 01; consumer-side close = guard (plan gate) that loud-fails `azurerm_role_definition` against smalt |
| S3 | containerApp/CAE 2024-03-01-first with fallback ladder | skewed, self-healing | compat pin row so the wasted-PUT is visible; optionally provider sends 2023-05-01 first |
| S4 | memory "1Gi"→numeric coercion retry | skewed, self-healing | same pin row as S3 (wasted-PUT visibility) |
| S5 | kind cluster name `smalt` unnamed in consumer docs | skewed-by-omission | one README line naming cluster `smalt` |
| S6 | TF range 1.9–1.13 vs posh needs ≥ 1.14 | unpinned | courtroom README floor raise to >= 1.14 (docs-only) or TF constraint bump |
| S7 | two rc writers, one concept | unpinned | fold posh-install to call `scripts/dev_overrides.sh` |
| S8 | no compatibility pin exists at all | **unpinned (root row)** | pin file (e.g. `smalt/adapters/terraform-provider-smalt/compat-pin.json`: provider SHA, per-type api-version tops, payload laws) consumed by the posh-court gate so a registry-top or provider-constant change fails the court instead of landing silently — this is the mechanical arm of GAP5(b) (`~/smalt/docs/jira/posh/v26.10.30/gaps/05-ci-cd.md` row b), referenced not duplicated |

Aligned cells (no row): resource group, key vault + secrets, UAI, FIC, LAW,
storage, role assignment, managedEnvironmentId shape, location shape,
traffic-on-update shape.

## Status line

PARTIAL — census read from disk this session (all file:line citations above are
real reads); skew rows S1-S8 identified; no court executed and no pin file
landed (S8 is the open close). GAP5(b) remains open by design.
