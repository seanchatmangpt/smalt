# SDK lane TS-1 — real @azure/arm-resources (TypeScript) against the smalt ARM plane

- **Date**: 2026-10-16 · **Lane**: lane333
- **Repo/SHA**: `/Users/sac/smalt` @ `main` `fd9cfea`
- **SDK**: `@azure/arm-resources` (from `test/sdk-full/node_modules`)
- **Runtime**: Node, macOS arm64 (Darwin 25.2.0)
- **Substrate**: lane333 persistent substrate, anonymous auth, ARM 39796 / ARM-TLS twin 39800, `MIX_BUILD_ROOT=_build-lane333`, under `flock /tmp/smalt-substrate.lock` discipline (fd closed)
- **Probe**: `test/sdk-full/arm-resources.probe.mjs` with `SMALT_TS_ARM_PORT=39796 SMALT_TS_ARM_TLS_PORT=39800 NODE_TLS_REJECT_UNAUTHORIZED=0`
- **Verdict**: 8/11 probes passed; 3 executed divergences, all registered OPEN (KD-30/31/32)

## executed commands (receipt)

```bash
NODE_TLS_REJECT_UNAUTHORIZED=0 SMALT_TS_ARM_PORT=39796 SMALT_TS_ARM_TLS_PORT=39800 \
  node test/sdk-full/arm-resources.probe.mjs   # exit 1 (3 divergences)
```

## results (2026-10-16)

| probe | outcome | detail |
|---|---|---|
| sts: client_credentials token over TLS (raw fetch) | pass | STS mint 200 |
| subscriptions list (raw GET with STS-minted Bearer) | pass | 200 |
| locations list (raw GET) | **divergence** | 404 RouteNotFound — KD-30 (OPEN) |
| resourcegroup createOrUpdate | pass | 201/200 |
| generic resource create: NSG (LRO beginCreateOrUpdateById + pollUntilDone) | pass | LRO terminal |
| generic resource get: NSG (getById) | pass | 200 |
| resources listByResourceGroup | **divergence** | 404 RouteNotFound — KD-31 (OPEN) |
| resourcegroup update (tags PATCH) | **divergence** | 404 RouteNotFound — KD-30/31/32 family, KD-32 (OPEN) |
| generic resource delete: NSG (LRO beginDeleteById + pollUntilDone) | pass | LRO terminal |
| resourcegroup delete (LRO beginDelete + pollUntilDone) | pass | LRO terminal |
| resourcegroup get-after-delete → 404 | pass | 404 correct |

The three executed divergences match the v26.10.14 witness set exactly
(KD-30 locations 404, KD-31 list-by-rg 404, KD-32 RG PATCH 404 — all
RouteNotFound, stable). Probe fleet itself is green apart from these three
registered OPEN rows.

## notes

- ts-cosmos and ts-keyvault NOT run this window: their harnesses hardcode the
  canonical egress/ARM ports (8443/9443), which are held by the user's live
  enforce-mode substrate (pid 882). Port law: no eviction. Loud skip, not a
  faked pass.
