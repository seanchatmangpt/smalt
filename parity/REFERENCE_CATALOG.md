# reference catalog — Azure emulation, mocking, and testing tools

Surveyed 2026-10-28 (web + GitHub, live checks) for candidate **reference
targets and validation methodologies** beyond the two already in the parity
stack (Azurite, Cosmos DB Emulator). Constraint throughout: this machine has
**no admin, no Docker, no WSL, no MSVC** — feasibility is judged against
that box. All facts below were verified against project pages / GitHub
releases on the survey date.

Rows marked **parity-ready** can run here today and slot into
`parity/run.mjs` as new target adapters (same `SMALT_PARITY_*` /
`PARITY_*` env contract as the existing azurite/emulator targets).

## tier 1 — runnable on this box now

| tool | what it is | Windows here | overlap with smalt | validation role |
|---|---|---|---|---|
| **AzureEventGridSimulator** (pm7y, v6.0.0, ~96★, active daily, MIT) | .NET self-contained Event Grid simulator: topics, subscriptions, event delivery, webhooks (CloudEvents + EventGrid schema), dead-lettering | **yes — `AzureEventGridSimulator-win-x64-6.0.0.zip`** (self-contained, no .NET install) | smalt mounts Event Grid (`:eventgrid_response_mode`; egress eventgrid routes) — **parity-ready**: a new `eventgrid` suite diffing smalt vs the simulator |
| **Azure SDK TestProxy** (Azure/azure-sdk-tools, official) | the record/playback proxy the Azure SDK teams use; standalone release `test-proxy-standalone-win-x64.zip`; also `dotnet tool` | **yes — self-contained win-x64 zip** | everything — it is methodology, not a service | **golden-corpus validation**: recordings of REAL Azure request/response pairs (from SDK repo test assets, or recorded once by anyone with an Azure sub) become the reference; replay the same requests at smalt and diff responses. No Azure account needed once recordings exist. Complements the live-emulator diffs with real-cloud data |
| **miniblue** (moabukar, v0.8.0, ~450★, Go, MIT) | single ~8MB binary emulating 28 services behind LocalStack-style ports (4566 data / 4567 ARM+metadata); `azlocal` CLI; azurerm Terraform against `localhost:4567` | **yes — `miniblue-windows-amd64.exe` + `azlocal-windows-amd64.exe` release assets** | Blob/Queue/Table/Cosmos/KeyVault/ServiceBus/EventGrid/AppConfig + **ARM control plane** (resource groups PUT on 4567) — the ARM overlap nothing local currently covers | **parity-ready**: second reference for every storage-family suite (three-way diff smalt vs Azurite vs miniblue), plus the first local ARM reference for the 9443 control plane |
| **Azure Functions Core Tools** (official) | local Functions runtime (not a service emulator; runs/publishes function code) | **already installed on this box** (`C:\Program Files\Microsoft\Azure Functions Core Tools`) | out of smalt's plane | local-run smoke target only; not a parity oracle |

## tier 2 — blocked here today, unblock paths known

| tool | what it is | blocker here | unblock | validation role |
|---|---|---|---|---|
| **Topaz** (TheCloudTheory, v1.10.222-preview, .NET, Apache-2.0 → dual-license from 1.11) | the most complete third-party Azure emulator: **ARM control plane + Bicep/ARM/Terraform(azurerm+AzAPI) deployments, Entra ID tenant + RBAC emulation**, Blob/Table/Queue, KeyVault, ServiceBus, EventHubs, ACR, AppConfig, Cosmos, EventGrid, Redis, APIM, LogAnalytics, AppInsights; `llms.txt` docs index | release assets are linux/osx only (incl. `topaz-host-linux-x64`); distroless Docker image needs Docker; building from source needs .NET SDK + **MSVC** (absent) | one elevated session: `wsl --install` → Docker/Podman (run the image), or VS Build Tools + `dotnet publish -r win-x64` | **the** ARM/Entra/RBAC parity reference — smalt's 9443 control plane, STS/oauth2 surface, and Bicep/terraform deploy flows finally get a peer; also a 3rd data-plane opinion |
| **floci-az** (floci-io, v0.15.0, ~800★, Java/Quarkus, MIT) | single-port (4577) emulator: Blob/Queue/Table, AppConfig, Cosmos NoSQL with **embedded SQL dialect**, KeyVault, EventHubs (AMQP), Functions, ARM-ish (APIM/VNet/VM/Redis/ACR); native-image startup <100ms; path-routed `/{account}-queue/` style | no prebuilt binary in releases; run needs JVM (scoop `temurin-lts` works) or a Quarkus build | `scoop install temurin-lts` + build/run from source | interesting 2nd Cosmos-SQL opinion (embedded engine, same design point as smalt's `cosmos_sql`); note its path-routing diverges from real Azure URLs — adapter must map endpoints |
| **Azure Service Bus emulator** (official) | full SB emulator | Docker-only image | `wsl --install` + Docker | unlocks the `amqp://…:5672` parity leg (currently the big smalt surface with no reference at all) |
| **Azure Event Hubs emulator** (official) | full EH emulator | Docker-only image | same | unlocks the 5673 EH leg |
| **Testcontainers** (.NET/Java/Python/Go modules wrapping Azurite/Cosmos/SB emulators) | orchestration layer over the same emulators | Docker-only | same | none beyond what its underlying emulators give; only worth it once Docker exists |

## tier 3 — noted, low value for this box now

- **clocal-azure** (lakindu95) — Python "localstack-for-Azure" concept; small and effectively dormant.
- **WireMock (standalone jar)** — generic HTTP record/mock; needs a JVM; useful only if we want hand-built ARM mocks, which real emulators above supersede.
- **oidc/Entra mock servers** — nothing significant standalone found (searches returned <5★ projects); the identity-plane answer is Topaz (Entra+RBAC) and miniblue (managed identity), not a standalone mock.
- **arm-ttk / PSRule.Azure** — static ARM/Bicep linting; complements (not compares) emulators; PowerShell, runnable here; relevant only when smalt grows a Bicep/ARM-template deployment surface worth linting fixtures against.

## how these slot into the parity harness

Same pattern as the existing azurite target — each becomes an adapter in
`parity/targets.mjs` + a suite wiring in `parity/run.mjs`:

1. **eventgrid suite** (vs AzureEventGridSimulator, today): topic/sub
   lifecycle, event publish, delivery-shape diff.
2. **miniblue target** (today): env `PARITY_MINIBLUE_*` (4566/4567); every
   storage-family suite gains a third column; new `arm` suite drives
   ResourceManagementClient at `http://127.0.0.1:4567` vs smalt's 9443.
3. **test-proxy golden corpus** (today, tooling work): a `parity/corpus/`
   runner that feeds recorded real-Azure request pairs to smalt and diffs
   normalized responses — cloud-truth parity without any cloud.
4. **Topaz + SB/EH emulators** (post-unblock): ARM/Entra/RBAC suite + the
   AMQP legs; the `--skipApiVersionCheck`-class flags and cert handling go
   in the adapters, never in the suites.

Survey receipts: DuckDuckGo ("azure local emulator tools…"), project sites
topaz.thecloudtheory.com / floci.io / miniblue.io, GitHub release APIs
(assets enumerated via `gh api repos/.../releases`). Star counts and
"active" claims are as-of-2026-10-28.
