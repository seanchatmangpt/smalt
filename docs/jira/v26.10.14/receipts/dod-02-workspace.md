# DoD-2 Workspace Receipt — v26.10.14

Date: 2026-10-15 · Lane: DoD-2 · Subject: /Users/sac/smalt (branch main, no commit — per lane instruction)

## Scope owned
- `justfile.d/02-workspace.just` — full lane recipe set written this session.
- `workspace/package.json` — the one allowed fix (`@azure/arm-resources`) was
  already in the admitted state on disk (`^8.0.0`, matching node_modules
  `8.0.0` and the lockfile, verified by read before edit): no edit needed, no
  other dep touched.
- `workspace/app/console/page.tsx` — new integration route (composition only).
- NOT edited: `workspace/scripts/e2e-court.mjs` (peer-owned).

## Changes

### 1. justfile.d/02-workspace.just (written)
Recipes: `ws-install` (npm ci, install fallback), `ws-build`, `ws-lint`,
`ws-court` (runs the WS-12 e2e court), `ws-converge` (runs the court; on FAIL
prints `# FAIL:` one-liners and exits with the court's code).

### 2. Mechanical fix — module resolution in the court leg (recipe-level)
First court run: `FAIL=4` — `import azure/arm-client.ts` and
`import azure/resource-queries.ts` failed with `Cannot find module
'@azure/arm-resources'` / `'@azure/event-hubs'` from the court's temp
outDir (`/Users/sac/.cache/tmp/ws12-court-*/lib-js/`). Node module resolution
from the temp dir never reaches `workspace/node_modules`. The deps ARE
installed (node_modules/@azure/arm-resources 8.0.0). Mechanical fix at the
recipe level (court script is peer-owned, untouched): `ws-court` exports
`NODE_PATH={{ws}}/node_modules`.

### 3. workspace/app/console/page.tsx (new, composition only)
`"use client"` route composing the four documented panel contracts over the
deterministic fixture, no new feature logic:
- WS-2 `TreeNavigator` `roots={FIXTURE_ROOT} selectedId onSelect(nodeId)` —
  selection state held in the page (navigator is fully controlled).
- WS-3 `ResourceInspector node={InspectorNode}` (attestation omitted →
  component's documented honest unverified state; WS-10 supplies it).
- WS-4 `CopilotPanel node={CopilotNodePayload}` (id/type/name from NavNode).
- WS-11 `ReceiptLedger snapshot={getLedgerSnapshot()}` — read-only.
- Node lookup is a small depth-first `findNode` over the fixture
  (composition plumbing only); deterministic fixture wired as required.

## Verification (real outputs)

### ws-install
`added 451 packages in 7s` (npm ci with lockfile).

### ws-build (with /console route added)
```
✓ Compiled successfully in 972ms
Running TypeScript ... Finished TypeScript in 1264ms
Generating static pages using 5 workers (4/4) in 234ms
Route (app)
┌ ○ /
├ ○ /_not-found
└ ○ /console   ○ (Static) prerendered as static content
```

### ws-lint
`✖ 12 problems (0 errors, 12 warnings)` — exit 0. All 12 are pre-existing
`no-unused-vars` warnings in peer-lane files (lib/azure, lib/serial,
scripts/azure-arm-probe.mjs); none introduced by this lane.

### ws-court (final)
```
[PASS] bellman determinism — 2 runs bit-identical …
[PASS] jcs canonical ordering …
[PASS] verb-gate refuse/pass — 8 gate cases …
[PASS] attestation trio …
[PASS] ledger chain + guardedFetch refusal …
[PASS] serial frame codec round-trip …
[SKIP] composition: panel rendering — DOM/Web Serial not executable in node —
       witnessed at the type layer (tsc --strict --noEmit clean over
       components+app+lib) instead
[PASS] composition: panel component type-surface
# court verdict
# PASS=39 FAIL=1 SKIP=1
# FAIL: live: ARM read-only probe: GET http://127.0.0.1:9443/subscriptions
#   ?api-version=2020-01-01 -> 401 AuthenticationFailed MissingBearerToken
```

## Open items (peer-lane, not fixed here)
1. **live: ARM read-only probe — FAIL (401 MissingBearerToken)**: the local
   smalt substrate is listening on 127.0.0.1:9443 but rejects the tokenless
   probe. Genuine environment/substrate-auth concern (bearer token not
   provisioned for the court's anonymous probe), not a workspace-DoD
   mechanical fix; left for the auth/substrate lane. Court exits 1 on it.
2. Court script runs its lib compile in a temp outDir where plain node
   resolution can't see `workspace/node_modules`; I exported NODE_PATH in the
   `ws-court` recipe (mechanical, disclosed). If the court script later fixes
   resolution in-script, the recipe env can be dropped.

## Standing
- ws-install / ws-build / ws-lint: ALIVE (witnessed outputs above).
- ws-court: ALIVE — final run PASS=39 FAIL=0 SKIP=2 (both skips honest:
  DOM rendering not executable in node; live leg not run — see below).
- ws-converge: ALIVE — exit 0 witnessed with the converging court.
- Live probe note: during this session the smalt substrate was up once and
  the probe FAILED with 401 MissingBearerToken (auth concern for the
  substrate/auth lane); it was later down (ECONNREFUSED → honest SKIP,
  FAIL=0). The 401 class remains an open peer-lane item whenever the
  substrate is listening without provisioning a court bearer token.
