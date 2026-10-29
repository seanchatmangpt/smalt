# BK-EXWV: deployment-group regression verify post EXPL12-R (-p/--parameters) + EXPL12-W (KD-15 handshake)

Standing: ALIVE · Context: solo · 2026-10-22 · Lane BK-EXWV (read-only verify; only this receipt written)

Subject: `smalt-cli/smalt_cli/commands/deployment.py` + `smalt-cli/smalt_cli/wire.py`
at HEAD `e06a937e`. No code edited by this lane. Read-only verify that the
deployment group shows no regression after (a) EXPL12-R reshaped its flags
(`-p/--parameters`) and (b) EXPL12-W rewired its wire path onto
`wire.arm_request` (KD-15 tokenless-first handshake).

## 1. ty suites fresh on HEAD

SMALT_CLI_LANE=bkexwv, `.venv-cli`, from `smalt-cli/`:

```
targeted:  pytest -m enforce tests/test_ty_deployment.py tests/test_ty_arm_handshake.py tests/test_ty_monitor.py
           -> 7 passed, 8 deselected in 12.48s
enforce:   pytest -m enforce tests/  -> 35 passed, 2 skipped, 114 deselected in 47.37s
anonymous: pytest -m anonymous tests/ -> 37 passed, 114 deselected in 13.55s
```

Identical counts to EXPL12-F's baseline (35/2/114, 37/114) — no regression,
including `test_deployment_parameters_file_materializes_value` (the EXPL12-R
parameters-file court).

## 2. Combined shape witnessed live (one session, leg trace over real httpx traffic)

Shared substrate TLS twin, `SMALT_ARM=https://127.0.0.1:9444`, cold token
cache, `deployment create dep-bkexwv77464 -g rg-bkexwv77464 -t tmpl.json
-p @/tmp/bkexwv/params.json -o json` — exit 0, `provisioningState: Succeeded`,
`resourcesApplied: ["bkexwv77464"]`:

```
PUT tokenless .../resourceGroups/rg-bkexwv77464/providers/Microsoft.Resources/deployments/dep-bkexwv77464 -> 401
POST tokenless https://127.0.0.1:9444/oauth2/v2.0/token -> 200
PUT bearer  .../resourceGroups/rg-bkexwv77464/providers/Microsoft.Resources/deployments/dep-bkexwv77464 -> 200
PUT tokenless .../Microsoft.Storage/storageAccounts/bkexwv77464 -> 401
PUT bearer  .../Microsoft.Storage/storageAccounts/bkexwv77464 -> 202
STS mints: 1
```

- The KD-15 challenge fires tokenless-first on the deployment PUT
  (EXPL12-W contract intact on the reshaped command).
- `@file` parameters parsed and materialized: the template's
  `[parameters('acct')]`/`[parameters('loc')]` resolved (storage account
  `bkexwv77464` applied, 202 accepted-for-provisioning).
- Child resource PUT re-challenges tokenless-first with the CACHED token on
  retry — same per-call contract as servicebus (contract-correct, chatty,
  not a defect; EXPL12-F note stands).

## 3. monitor metrics face on the CURRENT shared beam (BK-MON2 falsifier)

Beam ownership re-verified: pid **81426** (BK-SUB3's spawn) is LISTENing on
both 127.0.0.1:9443 and 127.0.0.1:9444 (lsof), up >14 min, parent pid 1 —
it still owns the shared substrate; no takeover.

Same-session cold-cache `monitor metrics rg-bkexwv77464 Microsoft.Storage
storageAccounts bkexwv77464` — exit 0, legs:

```
GET tokenless .../storageAccounts/bkexwv77464/providers/microsoft.insights/metrics -> 401
GET bearer  .../storageAccounts/bkexwv77464/providers/microsoft.insights/metrics -> 200
```

Body: 1441 buckets, 2 non-null totals (`1.0`, `2.0`) — real accumulator-free
rows, exit 0 (pre-fix this exact state ANDON'd with HTTP 500, per
EXPL12-W falsifier 4 and EXPL12-F's table). BK-MON2 falsifier satisfied on
the CURRENT shared beam pid 81426.

## 4. ty_monitor + ty_arm_handshake

Both suites inside the fresh sessions above (targeted run + full sessions):
passing, including the 3 EXPL12-W handshake courts
(`tests/test_ty_arm_handshake.py`) and the BK-MON1/3-era monitor courts.

## Verdict

**ALIVE.** Deployment group composes: `-p @file` parameters + tokenless-first
KD-15 handshake + child materialization, plus a healthy monitor metrics face
on the live shared beam, all on one HEAD with zero regressions. All compose.

Receipt: `docs/jira/v26.10.22/receipts/bkexwv-deploy-verify.md`
