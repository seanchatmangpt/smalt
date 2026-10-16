# WS-8 receipt — pure-Azure ARM client layer (workspace)

- Date: 2026-10-15
- Subject: /Users/sac/smalt v26.10.14 working tree (multi-lane)
- Lane: WS-8 (disjoint paths: workspace/lib/azure/arm-client.ts, credential.ts,
  resource-queries.ts, README.md, scripts/azure-arm-probe.mjs)

## Built

- workspace/lib/azure/credential.ts — SmaltTokenCredential
  (@azure/core-auth TokenCredential): raw STS client_credentials POST to
  `{armBase}/{tenant}/oauth2/v2.0/token`, caches until expires_in minus 60s
  slack, single-flight concurrent getToken, mintFresh/mintCount diagnostics.
  Raw POST is required because msal-node's OIDC instance discovery is not
  served by the emulator (endpoints_resolution_error; documented in
  docs/jira/v26.10.14/sdk-results/ts-arm-resources.md, constraint 1).
- workspace/lib/azure/arm-client.ts — ResourceManagementClient over
  SmaltTokenCredential, `{ endpoint: NEXT_PUBLIC_SMALT_ARM,
  apiVersion: "2021-04-01", allowInsecureConnection: true }` (api-version pin
  = emulator ceiling). Compile-time mutation ban: exports ArmReadFacade =
  Pick of READ ops only (resourceGroups.list/get, resources.list/getById);
  the concrete client never escapes the module. Ban witnessed with a
  @ts-expect-error consumer court (tsc passes only because createOrUpdate /
  beginDelete are genuinely absent from the facade type).
- workspace/lib/azure/resource-queries.ts — READ-only exports only
  (listSubscriptions, listResourceGroups, listResourcesByRG). listResourcesByRG
  reads the provider inventory (GET /subscriptions/{sub}/providers) because
  both generic resource list routes are missing on the emulator (below).
- workspace/lib/azure/README.md — module contracts + boot-shape findings
  (coexists with WS-9's data-plane sections in the shared file).
- workspace/scripts/azure-arm-probe.mjs — plain-node probe (boots nothing),
  walks STS mint -> subscriptions -> resource groups -> providers inventory,
  plus tokenless-401 and a KNOWN-DIVERGENCE line for the missing
  subscription-level /resources route.

## Verification ladder (all witnessed live)

- tsc: workspace tsc 5.x, --strict, three lane modules + ban court -> 0 errors
  (TYPECHECK-PASS, BAN-WITNESSED-NO-ERRORS).
- Substrate: booted by this lane under the substrate lock
  (shlock -f /tmp/smalt-substrate.lock -p <beam pid>; homebrew `flock` HANGS on
  this host — do not use it for the substrate lock), MIX_ENV=test,
  SMALT_TLS_CERTFILE/KEYFILE dev material, ports pinned
  (arm 9443 http, arm_tls twin 9444 https, egress 8443, amqp 5672, eh 5673),
  and `put_env(:smalt, :auth_mode, :enforce)` pinned (see finding F1).
  Beam pid at receipt time: 16561.
- Plain-node probe (NEXT_PUBLIC_SMALT_ARM=http://localhost:9443):
  [PASS] sts-mint :: status=200 segments=3 expires_in=3600
  [PASS] list-subscriptions :: 200, subs=1 first=00000000-...-000000000000
  [PASS] list-resource-groups :: 200, rgs=0
  [PASS] list-generic-resources-providers-inventory :: 200 resourceTypes=0
  [PASS] tokenless-401 :: 401 challenge="Bearer error=invalid_token,
         MissingBearerToken"
  KNOWN-DIVERGENCE: GET /subscriptions/{sub}/resources -> 404 RouteNotFound
  exit 0.
- TS-layer driver (lane modules compiled with tsc, driven from
  workspace cwd, NEXT_PUBLIC_SMALT_ARM=https://localhost:9444,
  NODE_TLS_REJECT_UNAUTHORIZED=0):
  TS listSubscriptions: [{"subscriptionId":"00000000-0000-0000-0000-000000000000","displayName":"Sovereign Smalt Subscription","state":"Enabled"}]
  TS listResourceGroups: 0 rg(s)
  TS listResourcesByRG(inventory): {"id":"/subscriptions/00000000-...-000000000000","namespace":"Microsoft.Resources","subscriptionId":"00000000-...-000000000000","resourceTypes":[]}
  export surface: listResourceGroups,listResourcesByRG,listSubscriptions (reads only)
  exit 0.

## Findings (wire-evidenced this session)

- F1 — auth gate is boot-shape-dependent: config/test.exs sets
  `config :smalt, :auth_mode, :anonymous`, so a MIX_ENV=test substrate WITHOUT
  an explicit `put_env(:smalt, :auth_mode, :enforce)` accepts tokenless AND
  tampered bearer requests (witnessed 200 on two substrate boots this
  session, raw curl). config.exs default is :enforce. Any auth-court probe
  that reuses an anonymously-booted substrate is vacuous. Probes/booters must
  pin :enforce. Subject-side: consider whether test.exs's anonymous default
  should exist at all given the 401 rows other courts claim.
- F2 — subscription-level generic list missing:
  GET /subscriptions/{sub}/resources -> 404 RouteNotFound (raw curl,
  authed). Extends divergence D2 (per-RG generic list missing). Real Azure
  serves 200 value[]. The witnessed generic read on the emulator is
  GET /subscriptions/{sub}/providers (200, resourceTypes inventory).
- F3 — SDK tier cannot ride plain HTTP: @azure/core-rest-pipeline refuses
  Bearer over non-https ("Bearer token authentication is not permitted for
  non-TLS protected (non-https) URLs", witnessed as a live throw from
  bearerTokenAuthenticationPolicy.js). Point the SDK at the :9444 TLS twin.
- F4 — homebrew `flock` on this host HANGS indefinitely on
  `flock -x /tmp/smalt-substrate.lock -c ...` (witnessed, killed after 120s).
  Use shlock keyed to the beam pid (pattern in the probe header comment /
  receipt) for the substrate lock.
- F5 — workspace/package.json pins @azure/arm-resources ^21.3.1, which does
  NOT exist on the npm registry (latest published is 8.0.0; registry metadata
  pulled this session). node_modules currently holds 8.0.0. WS-1 should
  correct the manifest pin.

## Divergences not fixed in this lane

- F1/F2/F5 are subject-side; recorded here and in README boot-shape notes.
- Lane build artifacts cleaned (.ws8-build, .ws8-ban, /tmp/ws8-js removed);
  no stray build dirs left in workspace/.

## Standing

ALIVE for the read path: STS mint -> subscriptions -> resource groups ->
providers inventory walked live through both the raw-fetch probe and the real
@azure/arm-resources SDK tier against a substrate this lane booted and locked.
