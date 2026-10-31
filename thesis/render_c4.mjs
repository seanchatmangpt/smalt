import { chromium } from '/Users/sac/cai/courtroom-platform-az/node_modules/playwright/index.mjs';
import fs from 'fs';
import path from 'path';

const outDir = '/Users/sac/smalt/thesis/figures';
fs.mkdirSync(outDir, { recursive: true });

const diagrams = [
  {
    name: 'c4_01_system_landscape',
    title: 'C4 Level 0: Enterprise System Landscape & Sovereign Federation',
    def: `
graph TB
  subgraph LawFirmFederation["Enterprise Law Firm Federation (Kirkland & Ellis LLP / Multi-Tenant)"]
    Counsel["Litigation Lead Counsel<br><i>[Person: sean@kirkland.com]</i>"]
    SecOps["Enterprise Infosec & SOC2 Auditors<br><i>[Person: KE Infosec]</i>"]
    DevOps["Platform Engineering Team<br><i>[Person: Dilip, Anirudh, Sean]</i>"]
  end

  subgraph SovereignBoundary["Sovereign Hermetic Execution Boundary (P28-SIL / Zero-Cloud)"]
    CourtroomSys["Courtroom AI Litigation Intelligence Platform<br><i>[Software System]</i><br>Consolidated Single ContainerApp Architecture"]
    SmaltSys["Smalt Sovereign Cloud Emulation Plane<br><i>[Software System: 127.0.0.1:9443]</i><br>ARM + STS + KeyVault + BEAM/DETS"]
    VerifyCourt["Adversarial Verification & Process Mining Court<br><i>[Software System]</i><br>pm4pytest + wasm4pm + POSH Mutation Court"]
  end

  subgraph ExternalServices["Enterprise Identity & Compliance Sinks"]
    EntraID["Microsoft Entra ID<br><i>[External IdP]</i><br>SAML 2.0 / FIDO2 MFA"]
    CriblSIEM["Azure Event Hubs / Cribl SIEM<br><i>[External Telemetry Sink]</i><br>x-ms-matter-id Attributed Stream"]
    CRMHVault["CRMH Cold Archive<br><i>[External Compliance Store]</i><br>14-Day Immutable Parquet Retention"]
    IMDS["Public Cloud IMDS (169.254.169.254)<br><i>[Untrusted Egress Target]</i>"]
  end

  Counsel -->|"1. Authenticates & orchestrates matters"| CourtroomSys
  DevOps -->|"2. Applies kirkland.tfvars & reusable modules"| SmaltSys
  SecOps -->|"3. Audits IEEE OCEL 2.0 & BLAKE3 receipts"| VerifyCourt
  CourtroomSys -->|"4. SAML 2.0 SP-Initiated SSO"| EntraID
  CourtroomSys -->|"5. Grounded ARM / KeyVault / Turnstile I/O"| SmaltSys
  CourtroomSys -->|"6. Emits matter-tagged audit events"| CriblSIEM
  CourtroomSys -->|"7. Publishes daily Parquet exports"| CRMHVault
  CourtroomSys -.->|"8. HARD REFUSED (HTTP 403 Trap)"| IMDS
  SmaltSys -->|"9. Streams causal E2O/O2O traces"| VerifyCourt
`
  },
  {
    name: 'c4_02_system_context',
    title: 'C4 Level 1: Courtroom AI Platform System Context',
    def: `
graph LR
  User["Litigation Counsel / Legal Ops<br><i>[Person]</i><br>Reviews transcripts, segments, & juror profiles"]
  Admin["Super Admin / Case Provisioner<br><i>[Person]</i><br>Creates tenant VPCs & matter workspaces"]
  Platform["<b>Courtroom AI Platform</b><br><i>[System Under Test]</i><br>Consolidated ContainerApp: ca-kirkland-consolidated<br>Tenant: kirkland | Matter: KIRK-2026-9042"]
  Entra["Microsoft Entra ID<br><i>[External System]</i><br>SAML 2.0 Signing Certificate & Group Policy"]
  Smalt["Smalt Sovereign Substrate<br><i>[System: 127.0.0.1:9443]</i><br>Local ARM Plane & Cryptographic Receipt Authority"]
  SIEM["Enterprise SIEM (EventHubs)<br><i>[External System]</i><br>Real-time Audit Ingestion (env=dev01)"]
  CRMH["CRMH Blob Storage<br><i>[External System]</i><br>14-Day Lifecycle Enforced Parquet Store"]

  User -->|"HTTPS :3001 (SAML Session Cookie)"| Platform
  Admin -->|"Triggers Terraform Base Template"| Platform
  Platform -->|"Verifies Assertion Signature & Groups"| Entra
  Platform -->|"REST over Loopback + BLAKE3 Turnstile"| Smalt
  Platform -->|"Streams siem.audit.delivered"| SIEM
  Platform -->|"Writes crmh_kirkland_*.parquet"| CRMH
`
  },
  {
    name: 'c4_03_container_topology',
    title: 'C4 Level 2: Multi-Plane Container Topology (Next.js <-> Terraform <-> Go <-> Elixir)',
    def: `
graph TB
  subgraph Plane1["Plane 1: Presentation & Client Harness (Node.js v22 / TypeScript)"]
    Playwright["Playwright Chromium Runner<br><i>[Headless Browser & Video Recorder]</i>"]
    NextWeb["@courtroom/web (:3001)<br><i>[Next.js 16.4.2 Standalone]</i><br>SSR App Router + Static CSS/SVG Assets"]
    ExpressAPI["@courtroom/api (:4001)<br><i>[Express SAML & Session Service]</i><br>/api/auth/me, /api/sso/status"]
  end

  subgraph Plane2["Plane 2: Infrastructure-as-Code Adapter (Go 1.23)"]
    TFProvider["terraform-provider-smalt<br><i>[Terraform Plugin SDKv2]</i><br>kirkland.tfvars + data.azurerm_key_vault_secret"]
  end

  subgraph Plane3["Plane 3: POSH Sovereign Membrane (Go 1.23)"]
    POSH["smalt.dev/posh<br><i>[UDS & HTTP Loopback Membrane]</i><br>BLAKE3 Turnstiles + Singleflight + IMDS Dialer Trap"]
  end

  subgraph Plane4["Plane 4: Sovereign State Core (Erlang/OTP 27 & Elixir BEAM)"]
    BEAM["Smalt BEAM Core (:9443)<br><i>[Cowboy HTTP + OTP GenServers]</i><br>STS RS256 Minter + ARM Router + DETS Tables"]
  end

  subgraph Plane5["Plane 5: Formal Verification & Process Mining Court"]
    OCELFile["IEEE OCEL 2.0 JSON Log<br><i>[9 Events, 6 Objects, O2O Graph]</i>"]
    PM4Py["pm4pytest + validate_ocel2.py<br><i>[Python 3.13 Petri Net TBR Court]</i>"]
  end

  Playwright -->|"HTTP GET / & /dashboard"| NextWeb
  NextWeb -->|"Proxy /api/auth/me"| ExpressAPI
  Playwright -->|"Direct ARM Client (mintToken, arm)"| POSH
  TFProvider -->|"Singleflight ARM Reconcile"| POSH
  POSH -->|"Length-Prefixed UDS / Loopback"| BEAM
  POSH -->|"Emits Signed OCEL 2.0 Trace"| OCELFile
  OCELFile -->|"Evaluates Fitness=1.0 & SLA<=500ms"| PM4Py
`
  },
  {
    name: 'c4_04_component_nextjs_web',
    title: 'C4 Level 3: Plane 1 Component Architecture (@courtroom/web & Harness)',
    def: `
graph TB
  subgraph NextJSApp["apps/web/src (Next.js 16.4.2 App Router)"]
    RootLayout["app/layout.tsx<br><i>[RootLayout]</i><br>Cormorant Garamond + globals.css"]
    SignInPage["app/page.tsx<br><i>[SignInPage]</i><br>Entra ID SSO Highlights & Alerts"]
    DashPage["app/dashboard/page.tsx<br><i>[DashboardPage]</i><br>Identity Summary & 5 Security Checks"]
    BrandComp["components/Brand.tsx & icons.tsx<br><i>[UI Primitives]</i>"]
    SessionLib["lib/session.ts & backend.ts<br><i>[Session Verifier]</i><br>interpretSessionResponse()"]
  end

  subgraph HarnessSuite["apps/web/test/harness (Chicago Classicist Vitest Suite)"]
    SmaltClient["lib/smalt-client.ts<br><i>[Real Wire Client]</i><br>mintToken(), arm(), substrateUp()"]
    ResidueSweep["lib/residue.ts<br><i>[Conservation Gate]</i><br>Asserts RESIDUE = 0"]
    CrossPlaneTest["crossplane/crossplane.test.ts<br><i>[4-Plane Integration]</i>"]
    DomainTests["tenant / container / crmh / siem / vault / ux / nfr<br><i>[20 Test Files, 68 Assertions]</i>"]
  end

  RootLayout --> SignInPage
  RootLayout --> DashPage
  SignInPage --> BrandComp
  SignInPage --> SessionLib
  DashPage --> BrandComp
  DashPage --> SessionLib
  CrossPlaneTest --> SmaltClient
  DomainTests --> SmaltClient
  DomainTests --> ResidueSweep
`
  },
  {
    name: 'c4_05_component_terraform_provider',
    title: 'C4 Level 3: Plane 2 Component Architecture (terraform-provider-smalt)',
    def: `
graph LR
  TFVars["kirkland.tfvars<br><i>[Tenant Config]</i><br>client_slug=kirkland<br>crmh_retention=14"]
  ProviderRoot["internal/provider/provider.go<br><i>[Schema & Config]</i><br>Endpoints -> 127.0.0.1:9443"]
  DataKV["internal/provider/data_sources_v1.go<br><i>[data azurerm_key_vault_secret]</i><br>Versionless Secret Read"]
  ResGroup["internal/provider/resources_v1.go<br><i>[ARM Resources]</i><br>ResourceGroup, ContainerApp, Vault"]
  SFGroup["singleflight.Group<br><i>[Concurrency Deduplicator]</i><br>Context Cancellation Isolated"]
  HTTPTransport["ARM HTTP Client<br><i>[Loopback Transport]</i><br>Verifies x-smalt-receipt-turnstile"]

  TFVars --> ProviderRoot
  ProviderRoot --> DataKV
  ProviderRoot --> ResGroup
  DataKV --> SFGroup
  ResGroup --> SFGroup
  SFGroup --> HTTPTransport
`
  },
  {
    name: 'c4_06_component_posh_membrane',
    title: 'C4 Level 3: Plane 3 Component Architecture (Go POSH Sovereign Membrane)',
    def: `
graph TB
  Listener["internal/server/server.go<br><i>[TCP & UDS Listener]</i><br>MaxFrameBytes = 4 MiB"]
  Pool["framePool (sync.Pool)<br><i>[Zero-Alloc Scratch]</i><br>maxPooledFrameBytes = 64 KiB"]
  PeerCred["peercred_darwin.go / linux.go<br><i>[Kernel Socket Creds]</i><br>LOCAL_PEERCRED / SO_PEERCRED"]
  ReceiptEngine["internal/receipt/receipt.go<br><i>[Cryptographic Turnstile]</i><br>BLAKE3-256 Content + Timestamp Sealing"]
  EgressDialer["internal/egress/dialer.go<br><i>[Socket Trap]</i><br>Blocks 169.254.169.254, ::ffff:169.254.169.254, 0.0.0.0"]
  Mutator["internal/mutation/mutator.go<br><i>[AST Mutation Engine]</i><br>Binary, Unary, & Branch Mutants"]

  Listener --> Pool
  Listener --> PeerCred
  Listener --> ReceiptEngine
  Listener --> EgressDialer
  Mutator -.->|"Proves Non-Vacuity"| ReceiptEngine
  Mutator -.->|"Proves Non-Vacuity"| EgressDialer
`
  },
  {
    name: 'c4_07_component_elixir_beam',
    title: 'C4 Level 3: Plane 4 Component Architecture (Elixir BEAM Sovereign Core)',
    def: `
graph TB
  Sup["Smalt.Application<br><i>[OTP Supervisor]</i><br>one_for_one Fault Tolerance"]
  Cowboy["Plug.Cowboy Endpoint (:9443)<br><i>[HTTP/1.1 & HTTP/2 Listener]</i>"]
  AuthPlug["Smalt.Plugs.BearerAuth<br><i>[JWT Gate]</i><br>Refuses MissingBearerToken (401)"]
  STSMinter["Smalt.STS.TokenMinter<br><i>[OAuth2 v2.0 Engine]</i><br>/smalt/oauth2/v2.0/token (RS256)"]
  ARMRouter["Smalt.ARM.Router<br><i>[Resource Dispatcher]</i><br>Subscriptions, RGs, Vaults, ContainerApps"]
  DETSStore["Smalt.Store.DETS<br><i>[Durable Disk Term Store]</i><br>Atomic Read-Modify-Write"]

  Sup --> Cowboy
  Sup --> STSMinter
  Sup --> DETSStore
  Cowboy --> AuthPlug
  AuthPlug --> ARMRouter
  ARMRouter --> DETSStore
`
  },
  {
    name: 'c4_08_deployment_topology',
    title: 'C4 Deployment Diagram: Consolidated ContainerApp & Hermetic Loopback Topology',
    def: `
graph TB
  subgraph MacOSHost["macOS Darwin Host (Kernel 25.0.0 / Apple Silicon ARM64)"]
    subgraph ConsolidatedPod["Consolidated Container App Instance (ca-kirkland-consolidated)"]
      WebProc["Node.js Process (:3001)<br>@courtroom/web (.next/standalone)"]
      APIProc["Node.js Process (:4001)<br>@courtroom/api (Express)"]
    end

    subgraph SovereignDaemon["Smalt Sovereign Daemon (127.0.0.1:9443)"]
      POSHMem["Go POSH Membrane<br>(posh/run/posh.sock)"]
      BEAMNode["Erlang BEAM VM<br>(DETS Persistent Tables)"]
    end

    subgraph EgressFirewall["Kernel & Dialer Egress Firewall"]
      IMDSBlock["IMDS Sinkhole<br>169.254.169.254/32 -> HTTP 403"]
    end
  end

  WebProc -->|"Loopback HTTP"| APIProc
  APIProc -->|"Loopback HTTP :9443"| POSHMem
  POSHMem -->|"Unix Domain Socket"| BEAMNode
  POSHMem -->|"Traps Forbidden Egress"| IMDSBlock
`
  },
  {
    name: 'c4_09_ocel_hypergraph',
    title: 'IEEE OCEL 2.0 Object-to-Object (O2O) & Event-to-Object (E2O) Hypergraph',
    def: `
graph LR
  subgraph Objects["OCEL 2.0 Objects (6 Connected Entities)"]
    O1["<b>tenant/kirkland</b><br><i>[Tenant]</i><br>slug: kirkland"]
    O2["<b>matter/matter-9042</b><br><i>[Matter]</i><br>id: KIRK-2026-9042"]
    O3["<b>app/ca-kirkland-consolidated</b><br><i>[ContainerApp]</i><br>eval_score: 7"]
    O4["<b>storage/crmh-kirkland</b><br><i>[CRMHStorage]</i><br>retention_days: 14"]
    O5["<b>stream/siem-kirkland</b><br><i>[SIEMStream]</i><br>env: dev01"]
    O6["<b>turnstile/turnstile-blake3</b><br><i>[TurnstileDigest]</i><br>BLAKE3-256"]
  end

  subgraph Events["OCEL 2.0 Events (4 Happy + 5 Adversarial)"]
    E1["evt-001: tf.resource.provisioned (t=0ms)"]
    E2["evt-002: posh.turnstile.verified (t=10ms)"]
    E3["evt-003: crmh.export.completed (t=25ms)"]
    E4["evt-004: siem.audit.delivered (t=40ms)"]
    E5["evt-005..009: 5 Option-B Refusals (t=55..115ms)"]
  end

  O1 -->|"owns (O2O)"| O2
  O2 -->|"runs_on (O2O)"| O3
  O2 -->|"exports_to (O2O)"| O4
  O2 -->|"streams_to (O2O)"| O5

  E1 -.->|"E2O"| O1
  E1 -.->|"E2O"| O2
  E1 -.->|"E2O"| O3
  E2 -.->|"E2O"| O2
  E2 -.->|"E2O"| O6
  E3 -.->|"E2O"| O2
  E3 -.->|"E2O"| O4
  E4 -.->|"E2O"| O2
  E4 -.->|"E2O"| O5
  E5 -.->|"E2O"| O1
  E5 -.->|"E2O"| O3
`
  },
  {
    name: 'c4_10_petri_net_fsm',
    title: 'Formal Object-Centric Petri Net (TBR Fitness = 1.000, m=0, r=0)',
    def: `
graph LR
  P0(("p0: Init<br>[1 Token]"))
  T1["<b>t1: tf.resource.provisioned</b><br>t = 0 ms"]
  P1(("p1: Provisioned"))
  T2["<b>t2: posh.turnstile.verified</b><br>t = 10 ms<br>BLAKE3 Sealed"]
  P2(("p2: Authenticated"))
  T3["<b>t3: crmh.export.completed</b><br>t = 25 ms<br>Delta = 25ms <= 500ms"]
  P3(("p3: Exported"))
  T4["<b>t4: siem.audit.delivered</b><br>t = 40 ms<br>env = dev01"]
  P4(("p4: AuditedSink<br>[Final Marking]"))

  P0 --> T1 --> P1 --> T2 --> P2 --> T3 --> P3 --> T4 --> P4
`
  },
  {
    name: 'c4_11_mutation_court_pipeline',
    title: '8-Stage Adversarial Anti-Vacuity Mutation Court Pipeline (100% Kill Rate)',
    def: `
graph TB
  Start["posh_mutation_court.py<br><b>Entry Gate</b>"]
  S1["<b>Stage 1: Baseline Positive Suite</b><br>go test -race ./internal/server ./internal/receipt ./internal/egress"]
  S2["<b>Stage 2: Turnstile Tamper Mutant</b><br>Flip 1 bit of HTTP payload -> Expect HTTP 403 Refusal"]
  S3["<b>Stage 3: IMDS Socket Trap Mutant</b><br>Dial 169.254.169.254 & ::ffff:169.254.169.254 -> Expect errEgressBlocked"]
  S4["<b>Stage 4: Singleflight Cancel Mutant</b><br>Cancel Caller G_0 -> Expect Callers G_1..G_31 Survive"]
  S5["<b>Stage 5: Chicago Adversarial Falsifiers</b><br>Omit/Forge Turnstile Header -> Expect Hard Refusal"]
  S6["<b>Stage 6: Kirkland 7-Gap OCEL Court</b><br>Validate 9 Events, 6 Objects, Fitness=1.0, SLA=25ms"]
  S7["<b>Stage 7: PM4Py Anti-Vacuity Mutants (M1, M2, M3)</b><br>M1: SLA 10ms (KILLED) | M2: Inverted FSM (KILLED) | M3: Unlinked O2O (KILLED)"]
  S8["<b>Stage 8: KeyVault Versionless Geometry</b><br>Verify Latest Secret Fiber Projection"]
  Crown["<b>VERDICT: ALL 8 GATES PROVEN NON-VACUOUS (ALIVE)</b>"]

  Start --> S1 --> S2 --> S3 --> S4 --> S5 --> S6 --> S7 --> S8 --> Crown
`
  },
  {
    name: 'c4_12_sequence_zero_mock_e2e',
    title: 'C4 Level 4: Zero-Mock End-to-End Cryptographic Execution Sequence',
    def: `
sequenceDiagram
  autonumber
  participant PW as Playwright Chromium
  participant Web as @courtroom/web (:3001)
  participant API as @courtroom/api (:4001)
  participant POSH as Go POSH Membrane
  participant BEAM as Elixir BEAM (:9443)
  participant OCEL as IEEE OCEL 2.0 Log
  participant PM4Py as pm4pytest Court

  PW->>Web: GET http://127.0.0.1:3001/ (Verify CSS 200 OK & Dark Theme)
  Web->>API: GET http://127.0.0.1:4001/api/sso/status
  API-->>Web: 200 OK {"configured": true}
  PW->>POSH: POST /smalt/oauth2/v2.0/token (client_credentials)
  POSH->>BEAM: Mint RS256 Signed JWT
  BEAM-->>PW: 200 OK {access_token: "eyJhbGciOiJSUzI1NiIs..."}
  PW->>POSH: PUT /subscriptions/.../resourcegroups/rg-kirkland-live (Bearer JWT)
  POSH->>BEAM: Commit ResourceGroup to DETS + Compute BLAKE3 Turnstile
  BEAM-->>PW: 201 Created [x-smalt-receipt-turnstile: 70376989b7c9...]
  PW->>POSH: GET /api/v1/health (No Bearer Token - Falsifier Probe)
  POSH-->>PW: 401 Unauthorized {"code": "AuthenticationFailed", "message": "MissingBearerToken"}
  POSH->>OCEL: Serialize 9 Events & 6 Objects (/tmp/kirkland_compliance_audit.ocel.json)
  PW->>PM4Py: execSync("pm4pytest check-conformance --min-fitness 1.0")
  PM4Py-->>PW: TAP ok 1 - fitness: 1.000 (0 missing, 0 remaining tokens)
  PW->>PM4Py: execSync("pm4pytest check-sla --sla tf:crmh:500.0")
  PM4Py-->>PW: TAP ok 1 - latency: 25.0ms <= 500.0ms
`
  }
];

console.log('[RENDER-12-C4] Launching Playwright Chromium to render 12 high-resolution C4 diagrams...');
const browser = await chromium.launch({ headless: true });

for (const diag of diagrams) {
  console.log(`[RENDER-12-C4] Rendering ${diag.name}...`);
  const page = await browser.newPage({ viewport: { width: 1500, height: 1050, deviceScaleFactor: 2 } });

  const html = `
<!DOCTYPE html>
<html>
<head>
  <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #ffffff; margin: 0; padding: 32px; display: inline-block; min-width: 1200px; }
    .box { border: 2px solid #0284c7; border-radius: 12px; padding: 24px; background: #f8fafc; }
    .title { font-size: 22px; font-weight: 800; color: #0f172a; margin-bottom: 20px; text-align: center; border-bottom: 2px solid #cbd5e1; padding-bottom: 12px; }
    .mermaid { display: flex; justify-content: center; background: #ffffff; padding: 16px; border-radius: 8px; border: 1px solid #e2e8f0; }
  </style>
</head>
<body>
  <div class="box" id="capture-target">
    <div class="title">${diag.title}</div>
    <div class="mermaid">
${diag.def}
    </div>
  </div>
  <script>
    mermaid.initialize({
      startOnLoad: true,
      theme: 'default',
      flowchart: { useMaxWidth: true, htmlLabels: true, curve: 'basis' },
      themeVariables: {
        primaryColor: '#e0f2fe',
        primaryBorderColor: '#0284c7',
        primaryTextColor: '#0f172a',
        lineColor: '#334155',
        secondaryColor: '#f1f5f9',
        tertiaryColor: '#ffffff'
      }
    });
  </script>
</body>
</html>
  `;

  await page.setContent(html, { waitUntil: 'networkidle' });
  await page.waitForSelector('.mermaid svg', { timeout: 15000 });
  await new Promise(r => setTimeout(r, 800));

  const element = await page.$('#capture-target');
  const pngPath = path.join(outDir, `${diag.name}.png`);
  await element.screenshot({ path: pngPath });
  console.log(`[RENDER-12-C4] Saved ${pngPath}`);
  await page.close();
}

await browser.close();
console.log('[RENDER-12-C4] All 12 C4 diagrams rendered successfully.');
