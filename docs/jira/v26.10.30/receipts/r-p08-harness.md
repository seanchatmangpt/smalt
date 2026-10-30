# r-p08-harness — v26.10.30 milestone gate (P08)

- window: v26.10.30 · date: 2026-10-30 ·
  subject: smalt working tree + courtroom-platform-az @ 338caed (read-only,
  git-archive materialization)
- standing: **ALIVE — every P-wave scenario witnessed on the kind cluster**

## The full ladder (each claim independently receipted)

| claim | scenario | standing | receipt |
|---|---|---|---|
| P01 zero-touch browser SAML sign-in, full Entra claim shape | real chromium in `r30-driver`, production @node-saml | **ALIVE** | r-p01-browser-saml.md |
| P02 SAML SLO round trip + store-level eviction | real chromium + RESP wire audit (`remainingKeys:0`) | **ALIVE** | r-p02-slo-roundtrip.md |
| P03 browser + openid-client OIDC code/PKCE, JWKS-verified RS256 id_token | real chromium + openid-client v6 | **ALIVE** | r-p03-browser-oidc.md |
| P04 10-concurrent browser contexts, zero wire desync | 10× chromium contexts × 5 mutations | **ALIVE (10/10)** | r-p04-concurrent-sessions.md |
| P05 tenant fence through browser→ingress→api | foreign-tenant flip: typed data-free denial, no session; restore → P01-PASS | **ALIVE (3/3)** | r-p05-tenant-fence-browser.md |
| P06 ACA ingress 308 + proxy-trust law | scenario-scoped CANONICAL_ORIGIN flip, 6 asserts | **ALIVE (6/6)** | r-p06-ingress-parity.md |
| P07 probe contract gates every scenario | the court's `s11_wait_ready` + typed exit 2 | **ALIVE** (folded) | r13-kind-e2e.md |
| P09 identity topology + CA trust chain (no TLS bypass) | r30 TLS front + driver CA trust + zero-bypass grep | **ALIVE** (folded) | r-p01 notes |

## The reproducible substrate

`bash scripts/courtroom_kind_court.sh` → **COURT-VERDICT: ALIVE, flow
9/9** — witnessed THREE times (runs 2/7/9) on baked manifests
(`k8s/courtroom-{api,smalt,web}.yaml`), zero cloud, zero mock IdP, zero
signature bypasses, production validators only.

## Hermeticity

The stack's runtime calls nothing outside the cluster: the SAML/OIDC
faces, the redis wire, and the consumer's Entra integration all resolve
to substrate faces by construction (zero `@azure/*` deps; the browser
flows' network traces touch only in-cluster services). No egress was
needed for any ALIVE verdict above.

## Defects this window's P-wave found and fixed (each wire-witnessed)

1. Missing `AudienceRestriction` (node-saml rejection).
2. Nested `AttributeStatement` burying the Entra claims (node-saml
   profile read only the outer node → `tenant_mismatch`).
3. Docker layer-cache staleness: baked beams out-dating source mtimes →
   boot compiles silently skipped (fixed: boot-time touch + --no-cache
   rebuilds).
4. RESP audit probe framing (court-side, the wire held the law).
5. openid-client v6's async PKCE challenge (harness-side; the substrate
   refused the garbage challenge correctly — its court fired).
