# gaps/INDEX.md — v26.10.30 Gap Report Register

Index of the gap reports in `docs/jira/posh/v26.10.30/gaps/`, with
per-report status (quoted from each file's own status line, re-read on
disk 2026-10-30) and the top-severity finding in each. Doc-lane D1,
2026-10-30; rows 13–37 appended by lane 52, 2026-10-30. No report content
is modified here; each report is the authority on its own findings.

| # | Report | Report status | Top-severity finding |
|---|--------|---------------|----------------------|
| 01 | `01-provider-azurerm-parity.md` | ALIVE (read + report; no provider code changed) | **G1 — BLOCKS-CONSUMER:** `azurerm_role_definition` is fully UNSUPPORTED (typed `roleDefinitionUnsupported` on all CRUD) while the consumer access env declares a custom plan role + assignment that references it; access-env create fails outright. (G7 "import" re-verified NOT a gap: ImportState implemented on all 10 consumer resources.) |
| 02 | `02-smalt-arm-vs-azure.md` | PARTIAL — ARM face serves the consumer surface | **A1 — HIGH:** smalt ARM `@api_versions` ceilings sit below azurerm-5.x pins for several families (log-analytics, AKS, FIC, key vault, Network); the monotonic gate refuses exactly the newer azurerm pins, so `InvalidApiVersionParameter` is the refused class. (A11's G7 clause superseded by GAP1 — see correction note in that file.) |
| 03 | `03-kind-vs-aca.md` | PARTIAL — kind ALIVE locally, 5 of 8 dimensions zero parity with ACA | **Ingress/TLS and Identity — HIGH x2:** kind has plain-HTTP NodePort ingress (no L7 proxy/managed TLS) and no workload identity, vs ACA's edge-TLS + per-app managed identity + KV-bound secrets; neither ACA platform behavior is exercised on kind today. |
| 04 | `04-posh-vs-charter.md` | PARTIAL — fences landed and partially receipted | **posh-court gate stands FAIL (0/8, kind disk preflight) and the posh turnstile is not enforced on any BEAM production call path**; also SPAF Rule 2 heap-BLAKE3 is a disclosed v1 trade and the ggen-rendered pipeline modules are dead code. |
| 05 | `05-ci-cd.md` | (status line in file; read 2026-10-30) | **Row b — Medium:** no path from smalt-green to courtroom-platform-az deploy — `deploy-dev.yml` gates only on its own CI; two repos, zero cross-repo gate, so courtroom can deploy against an unqualified smalt version. |
| 06 | `06-state-drift.md` | PARTIAL | **Row b — High:** import drift + unguarded local apply — consumer roots carry `imports.tf` pinned to real Azure ids but nothing mechanically forbids a local `apply -auto-approve` on a local-state lineage; fence is purely procedural. (Paired with row c — High: stage-7 residue probes never exercised against the tenant surface.) |
| 07 | `07-secrets-identity.md` | PARTIAL — prod wiring landed, local is structural divergence | **G1 — BLOCKED (prod deploy):** KV secret values provisioned by nobody — Terraform creates the vault + ACA `key_vault_secret_id` refs, but no resource/script ever writes `<slug>-session-secret` / `<slug>-idp-cert`; first `az containerapp update` resolves a nonexistent secret. |
| 08 | `08-ggen-coverage.md` | PARTIAL — graph + generation exist, outputs compile | **Generated artifacts orphaned on both tiers:** the only served route (`echo`) goes through the hand-wired registry; generated dispatcher + Elixir pipeline modules have zero hand-written imports (grep-verified), runtime SHACL validation is a stub, one generated module targets a nonexistent turnstile module, no byte-identical regen check. |
| 09 | `09-courts-matrix.md` | smalt composite court ALIVE; posh ladder PARTIAL_ALIVE (standing receipt FAIL 0/8); aux courts ALIVE | **posh-court has never witnessed exit 0** — standing receipt is FAIL 0/8 (kind disk preflight); plus gate-missing rows: Andon composite not wired (G3), verify.md §3 stage-table drift (G4, closed by docs lane D1 2026-10-30). |
| 10 | `10-observability.md` | PARTIAL — instrumentation exists and runs | **Row d — HIGH:** `measure.md` defines M1–Mn with named instruments but only one receipt (`receipts/measure/posh002-latency.json`) exists — the measure phase is on paper, not running; any metric without a current-cycle instrument run must read UNVERIFIED. |
| 11 | `11-kind-ops.md` | PARTIAL | **G11-1 — HIGH:** the `smalt:local`/hermetic image lacks `/posh/bin/posh` (or the sidecar command path is wrong) — `sts/smalt-backend` never reaches full READY, pod CrashLoopBackOff-class, "owner partition died" warnings recur. |
| 12 | `12-runbook.md` | PARTIAL — ladder fail-closed (ALIVE), clone-to-green path fragmentary | **No single doc names the full prereq set/ordering/cluster identity**; two README quickstarts disagree on the kind cluster name, and one doc claims a health endpoint that 401s (bearer-gated `/healthz`). |

## Cross-cutting reads

- The single most repeated block-class across reports: **courts/gates
  that exist on disk but have never flipped or never run green**
  (posh-court FAIL 0/8, stage-7 residue never mutation-flipped,
  invariant-gates without per-gate mutation legs — GAP9 §vacuity-missing).
- GAP1's provider-surface correction (G7 import implemented) supersedes
  the corresponding clause in GAP2 row A11 (annotated in-file).
- verify.md §6 (500-run DPMO) / §7 (SPC control plan) remain PLANNED —
  declared tollgates, not defects (GAP9 R4).

## Reports 13–37 (appended lane 52, 2026-10-30)

| # | Report | Report status | Top-severity finding |
|---|--------|---------------|----------------------|
| 13 | `13-two-provider-limbo.md` | ALIVE (2026-10-30, read-mostly sweep + live recipe execution) | Two-provider limbo mapped with a live-executed recipe — see file for the resolution path. |
| 14 | `14-kubeconfig-contexts.md` | **ALIVE** (all probes executed this session, 2026-10-30) | kubeconfig contexts vs canonical cluster name `smalt` — probe-verified divergence. |
| 15 | `15-receipt-formats.md` | **PARTIAL_ALIVE** — every schema/writer/reader read from disk | Receipt formats inventoried schema-by-schema; writers/readers present, uniformity gaps remain. |
| 16 | `16-allowlist-graph-skew.md` | PARTIAL (skew confirmed by live probe + read trace; no posh.yaml projection exists) | Op allowlist and route-graph skew confirmed live; the posh.yaml projection that would close it does not exist. |
| 17 | `17-unmapped-ports.md` | PARTIAL — cluster face is 4 of 13 ports; host face masked by a native host substrate binding the same loopback ports | Port matrix: only 4 of 13 ports reachable on the cluster face; host face masked by the G17 native beam. |
| 18 | `18-lease-residue.md` | **ALIVE** — census executed this session (`du -sh`, `lsof +D`, `ps eww`); no deletions performed | Lease residue censused (sizes, open fds, owning processes); cleanup left to the owning lanes. |
| 19 | `19-vocabulary-drift.md` | **PARTIAL** — glossary content complete and receipt-anchored; glossary home file NOT LANDED (per gap file) | Four charter terms have no code artifact at all; the INVARIANT gate's SPARQL has no runtime artifact; "gate" carries three in-tree meanings. (Home file `glossary.md` landed by lane 52, 2026-10-30.) |
| 20 | `20-registration-pins.md` | PARTIAL — drift risk mapped; gate exists and is read on disk | Provider registration pin vs KD register: `expectedResources = 12` / `expectedDataSources = 7` assertions pin the surface; drift risk mapped. |
| 21 | `21-env-precedence.md` | **PARTIAL** — full matrix built for every env var actually read in this repo | Env-var precedence matrix complete; conflicts/ambiguities documented per variable. |
| 22 | `22-import-formats.md` | PARTIAL (read-only census 2026-10-30; parser bodies re-read from disk) | Import format census — parser behavior documented; format coverage partial. |
| 23 | `23-secret-echo-staleness.md` | **ALIVE** — live wire probe executed this session (receipt in file) | Secret-echo staleness witnessed on the live wire, not inferred. |
| 25 | `25-court-green-runbook.md` | Runbook, live-witnessed 2026-10-30 — plane SPLIT, court FAIL 0/8 | posh-court green is blocked by (a) the lane-orphaned native beam owning 127.0.0.1:9443 (vacuous-green risk) and (b) kind node disk preflight 15864MB < 20000MB; ordered runbook + falsifying plane discriminator included. |
| 26 | `26-turnstile-live-path.md` | PARTIAL — the receipt **stamp** is ALIVE on the live TF apply path | Turnstile receipt stamping reaches the live apply path; full enforcement beyond the stamp remains open. |
| 27 | `27-invariant-gate-design.md` | PARTIAL — design grounded on live execution this session (rdflib 7.6.0) | INVARIANT gate design spec executed against real rdflib; runtime wiring not landed. |
| 28 | `28-andon-court-wiring.md` | PARTIAL — spec complete; wiring unimplemented. Driver ALIVE (unit tests) | Andon driver works standalone; wiring it into the court pipeline is specified but unimplemented. |
| 29 | `29-graph-config-source.md` | PARTIAL (spec + sketched diffs; nothing landed, regen-check not run) | Graph-as-config-source spec + diff sketches; no landing, no byte-identical regen check. |
| 30 | `30-dpmo-r-computation.md` | PARTIAL — the R definition, runner, and non-vacuity court executed this session | DPMO R computation: definition + runner + non-vacuity court ran; integration into the charter denominator remains. |
| 31 | `31-sla-clocks.md` | PARTIAL (design lane; no runner code landed, no court executed this session) | Per-gate SLA clocks (<60s/<40s/<10s/<5s) designed; no runner, no court. |
| 32 | `32-shacl-runtime-decision.md` | PARTIAL — decision specified from on-disk evidence (smalt working tree) | SHACL runtime decision recorded from on-disk evidence; enforcement pending. |
| 33 | `33-compat-pin.md` | PARTIAL — spec only this session; no pin file, no gate executed | Compatibility pin between consumer and substrate: spec only; the skew surface (see gap 24-class) is unpinned. |
| 34 | `34-secret-provisioning.md` | PARTIAL (read-only census 2026-10-30; every file:line re-read from disk) | Secret provisioning census — who writes which secret, per environment; gaps mapped. |
| 35 | `35-egress-mapping-decision.md` | **PARTIAL** — decision made and recorded (ALIVE as a decision) | Egress mapping decision recorded; implementation follows the decision, not yet landed. |
| 37 | `37-residue-to-green-ledger.md` | **ALIVE** — every path referenced verified on disk 2026-10-30 | Residue-to-green integration ledger: coordinator script paths all verified; residue cleanup → green path enumerated. |

## Addendum (2026-10-30, registry-sweep lane 49)

- Row 01 status is superseded in part: G1 (role_definition BLOCKS-CONSUMER) is CLOSED by
  lane C1 — see "Updates" section in `01-provider-azurerm-parity.md`. KD-01 flipped CLOSED
  in `posh/KNOWN_DIVERGENCES.md` §6; coverage gate green (0 missing, exit 0).
- G7/import-formats rows closed by C8 (executable import assertions, all 12 blocks).

## Addendum (2026-10-30, lane 9 — single-path onboarding)

- New row: `62-onboarding-single-path.md` — **ALIVE**: README §POSH designated
  canonical and copy-paste-tested (all 4 fenced commands verified against
  `just --list` / `command -v`); posh/README, adapters/terraform-provider-smalt/README,
  examples/README demoted to pointers. Drift table D1-D9 in the report.

## Addendum (2026-10-30, lane 7 — operator status command)

- New row: `60-status-command.md` — **ALIVE**: `just posh-status` upgraded to
  the single glance (scripts/posh_status.sh; 7 typed sections PLANE/PODS/
  ENDPOINTS/PROVIDER/GATES/LAST COURT/LAST ANDON; exit 0/2). 2x live runs +
  wire run recorded verbatim; current estate truthfully RED (court F3, andon
  RED) while gates/pods/endpoints/provider are green.
