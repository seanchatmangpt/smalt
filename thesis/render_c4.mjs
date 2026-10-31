import { chromium } from '/Users/sac/cai/courtroom-platform-az/node_modules/playwright/index.mjs';
import fs from 'fs';
import path from 'path';

const outDir = '/Users/sac/smalt/thesis/figures';
fs.mkdirSync(outDir, { recursive: true });

const diagrams = [
  {
    name: 'c4_context',
    title: 'C4 Level 1: System Context Diagram',
    def: `
graph TD
  User["Litigation Counsel / Legal Ops<br><i>[Person]</i>"]
  Platform["Courtroom AI Platform<br><i>[Software System]</i><br>Zero-Cloud Sovereign Enterprise System"]
  Entra["Microsoft Entra ID<br><i>[External System]</i><br>Corporate SAML 2.0 / IdP"]
  Smalt["Smalt Sovereign Substrate<br><i>[Software System]</i><br>ARM / BEAM / Key Vault Emulation (127.0.0.1:9443)"]
  SIEM["Enterprise SIEM / Event Hubs<br><i>[External System]</i><br>Audit & Cribl Telemetry Pipeline"]
  CRMH["Azure Blob Storage / CRMH<br><i>[External System]</i><br>14-Day Parquet Cold Storage"]

  User -->|"Manages cases, reviews evidence (HTTPS)"| Platform
  Platform -->|"Authenticates via corporate SSO (SAML 2.0)"| Entra
  Platform -->|"Provisions resources, retrieves secrets (REST / TLS)"| Smalt
  Platform -->|"Streams matter-attributed audit events"| SIEM
  Platform -->|"Exports daily case evidence (Parquet)"| CRMH
`
  },
  {
    name: 'c4_container',
    title: 'C4 Level 2: Container Diagram',
    def: `
graph TD
  Browser["Web Browser (Counsel Client)<br><i>[Container: Next.js Client]</i>"]
  Web["Next.js Web Frontend (:3001 / :3456)<br><i>[Container: Node.js / React 19]</i>"]
  API["Courtroom Express API (:4001)<br><i>[Container: TypeScript / Express]</i>"]
  POSH["POSH Membrane (UDS / Loopback)<br><i>[Container: Go Engine]</i>"]
  Substrate["Smalt Sovereign Core (:9443)<br><i>[Container: Erlang BEAM / DETS]</i>"]
  OCEL["IEEE OCEL 2.0 Store<br><i>[Container: JSON Log]</i>"]
  PM4Py["pm4pytest Conformance Court<br><i>[Container: Python 3.13]</i>"]

  Browser -->|"Interacts with UI (HTML/CSS/JS)"| Web
  Web -->|"Proxies auth & case API requests"| API
  API -->|"Validates STS & provisions cases"| Substrate
  Web -->|"Low-latency loopback calls"| POSH
  POSH -->|"Length-prefixed UDS framing"| Substrate
  POSH -->|"Emits causal events & turnstiles"| OCEL
  Substrate -->|"Emits ARM & Key Vault events"| OCEL
  OCEL -->|"Token-Based Replay (Fitness 1.0)"| PM4Py
`
  },
  {
    name: 'c4_component',
    title: 'C4 Level 3: POSH Component Diagram',
    def: `
graph TD
  Router["HTTP & Frame Router<br><i>[Go Component]</i>"]
  Turnstile["BLAKE3 Turnstile Sealer<br><i>[Go Component]</i>"]
  Singleflight["Singleflight Isolation Registry<br><i>[Go Component]</i>"]
  Egress["Egress Controller & IMDS Trap<br><i>[Go Component]</i>"]
  FramePool["Zero-Alloc Buffer Pool (sync.Pool)<br><i>[Go Component]</i>"]
  Wire["Scatter-Gather UDS Framer<br><i>[Go Component]</i>"]

  Router -->|"Borrow buffer"| FramePool
  Router -->|"Seal request receipt"| Turnstile
  Router -->|"Deduplicate concurrent callers"| Singleflight
  Router -->|"Dial socket"| Egress
  Egress -->|"Trap 169.254.169.254"| Router
  Router -->|"Write framed message"| Wire
`
  },
  {
    name: 'c4_sequence',
    title: 'C4 Level 4: Execution Sequence & Petri Net Trace',
    def: `
sequenceDiagram
  autonumber
  actor Test as Playwright Test Runner
  participant UI as Next.js Web (localhost:3001)
  participant API as Express API (localhost:4001)
  participant Smalt as Smalt Substrate (127.0.0.1:9443)
  participant POSH as Go POSH Membrane
  participant OCEL as IEEE OCEL 2.0 Store
  participant PM4Py as pm4pytest Conformance Engine

  Test->>UI: 1. Navigate to Sign-In (/ sign-in)
  UI->>API: 2. Query SSO Readiness (/api/sso/status)
  API-->>UI: 200 OK (configured: true)
  Test->>Smalt: 3. Mint STS OAuth Token (/smalt/oauth2/v2.0/token)
  Smalt-->>Test: RS256 Bearer Token
  Test->>Smalt: 4. Live PUT /resourcegroups/rg-kirkland-live
  Smalt-->>Test: 201 Created + x-smalt-receipt-turnstile (BLAKE3)
  POSH->>OCEL: 5. Emit tf.resource.provisioned & posh.turnstile.verified
  Test->>Smalt: 6. Trigger CRMH 14d Parquet Export
  Smalt->>OCEL: 7. Emit crmh.export.completed (Latency Delta = 25ms)
  Test->>POSH: 8. Malicious IMDS Probe (169.254.169.254)
  POSH-->>Test: HTTP 403 Hard Refusal (errEgressBlocked)
  POSH->>OCEL: 9. Emit egress.imds.refused
  Test->>PM4Py: 10. Execute check-conformance & check-sla
  PM4Py-->>Test: ok 1 - Fitness = 1.0, SLA = 25ms <= 500ms
`
  }
];

console.log('[RENDER-C4] Launching Playwright Chromium to render Mermaid C4 diagrams...');
const browser = await chromium.launch({ headless: true });

for (const diag of diagrams) {
  console.log(`[RENDER-C4] Rendering ${diag.name} (${diag.title})...`);
  const page = await browser.newPage({ viewport: { width: 1400, height: 1000, deviceScaleFactor: 2 } });
  
  const html = `
<!DOCTYPE html>
<html>
<head>
  <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #ffffff; margin: 0; padding: 40px; }
    .title { font-size: 20px; font-weight: bold; color: #1e293b; margin-bottom: 24px; text-align: center; }
    .mermaid { display: flex; justify-content: center; }
  </style>
</head>
<body>
  <div class="title">${diag.title}</div>
  <div class="mermaid">
${diag.def}
  </div>
  <script>
    mermaid.initialize({
      startOnLoad: true,
      theme: 'default',
      flowchart: { useMaxWidth: true, htmlLabels: true, curve: 'basis' },
      themeVariables: {
        primaryColor: '#e0f2fe',
        primaryBorderColor: '#0284c7',
        primaryTextColor: '#0369a1',
        lineColor: '#64748b'
      }
    });
  </script>
</body>
</html>
  `;
  
  await page.setContent(html, { waitUntil: 'networkidle' });
  await page.waitForSelector('.mermaid svg', { timeout: 10000 });
  await new Promise(r => setTimeout(r, 1000));
  
  const element = await page.$('body');
  const pngPath = path.join(outDir, `${diag.name}.png`);
  await element.screenshot({ path: pngPath });
  console.log(`[RENDER-C4] Saved high-res figure to ${pngPath}`);
  await page.close();
}

await browser.close();
console.log('[RENDER-C4] All C4 diagrams rendered successfully.');
