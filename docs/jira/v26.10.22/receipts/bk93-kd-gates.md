# BK-93: KD gate run — kd-stale / kd_flip (read-only) / docs-dod-check

**Standing**: ALIVE — all three gates exit 0; register clean, no pending flips, no new rows.

**Context**: solo

Witness-note (BK-100b format backfill): the verbatim blocks below record the
just-recipe SOURCE text (which pipes through `|| echo`), not the lane's own
invocation. The classified, actually-run read-only commands were:

```
$ just docs-dod-check
$ python3 scripts/kd_flip.py
$ just kd-stale
```

all exit 0; their outputs are the verbatim blocks below. (Read-only kd_flip
currently also prints an UNKNOWN-KD-IDS line for KD-166 — in-flight lane
tokens whose register mint has not landed; the `|| echo`-masked `just kd-stale`
form exits 0.)

**Date**: 2026-10-21

## Task

BK-85's KD-164 mint check: did a new KD row land in the canonical register?
Verify parse + receipt match if present.

## Findings

- **KD-164: NOT MINTED.** Canonical register
  `docs/jira/v26.10.21/KNOWN_DIVERGENCES.md` states "from KD-164 (highest minted
  id is KD-163)". No KD-164 row exists anywhere under `docs/jira/` except that
  pointer note. Highest minted id remains KD-163; 111 KD ids covered by the
  KD-COVERS map (130 files). Nothing to parse, no receipt to match — BK-85's
  mint has not landed.
- `just kd-stale` — no pending-witness rows (exit 0).
- `python3 scripts/kd_flip.py` (read-only) — FLIP-ELIGIBLE: 0, FLIP-PENDING-WITNESS: 0 (exit 0).
- `just docs-dod-check` — all 61 checked paths OK, 0 MISS (exit 0).

## Outputs (verbatim)

### `just kd-stale`

```text
#!/usr/bin/env bash
set -euo pipefail
python3 scripts/kd_flip.py 2>&1 | grep -E "FLIP-PENDING-WITNESS" || echo "[KD-STALE] no pending-witness rows"
FLIP-PENDING-WITNESS: 0
```

exit 0

### `python3 scripts/kd_flip.py` (read-only)

```text
KD-COVERS covers-map: 111 KD ids from 130 files
  KD-02: [CLOSED-SIMULATED] lib/smalt/data_plane/blob_storage.ex
  KD-03: [CLOSED-WITH-RECEIPT] lib/smalt/data_plane/blob_service.ex
  KD-06: [CLOSED-SIMULATED] lib/smalt/data_plane/cosmos.ex
  KD-08: [CLOSED-SIMULATED] lib/smalt/data_plane/cosmos.ex
  KD-09: [CLOSED-SIMULATED] lib/smalt/data_plane/cosmos.ex
  KD-10: [CLOSED-WITH-RECEIPT] lib/smalt/egress/KvRoutes.ex
  KD-100: [CLOSED-SIMULATED] lib/smalt/auth/sts_key.ex
  KD-103: [CLOSED-SIMULATED] lib/smalt/egress/KvRoutes.ex
  KD-104: [CLOSED-SIMULATED] lib/smalt/data_plane/certificates.ex
  KD-105: [CLOSED-SIMULATED] lib/smalt/data_plane/kv_pss.ex
  KD-106: [CLOSED-SIMULATED] lib/smalt/data_plane/skr.ex
  KD-108: [CLOSED-SIMULATED] lib/smalt/data_plane/blob_storage.ex
  KD-109: [CLOSED-SIMULATED] lib/smalt/egress/AppConfigRoutes.ex
  KD-11: [CLOSED-SIMULATED] lib/smalt/egress/KvRoutes.ex
  KD-111: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-112: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-113: [CLOSED-SIMULATED] lib/smalt/policy.ex
  KD-114: [CLOSED-SIMULATED] lib/smalt/application.ex, lib/smalt/auth/bearer.ex
  KD-115: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex
  KD-117: [CLOSED-SIMULATED] lib/smalt/application.ex
  KD-118: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/management_rpc.ex
  KD-119: [CLOSED-SIMULATED] lib/smalt/data_plane/kv_pss.ex
  KD-12: [CLOSED-SIMULATED] lib/smalt/data_plane/key_vault_actions.ex, lib/smalt/egress_router.ex
  KD-120: [CLOSED-WITH-RECEIPT] lib/smalt/messaging/amqp/management_rpc.ex
  KD-121: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex
  KD-122: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-123: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-124: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-125: [CLOSED-SIMULATED] lib/smalt/policy.ex
  KD-126: [CLOSED-SIMULATED] lib/smalt/egress/KvRoutes.ex
  KD-127: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex
  KD-128: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/management_rpc.ex
  KD-129: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex, lib/smalt/messaging/amqp/frame_codec.ex
  KD-130: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-131: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex
  KD-132: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex
  KD-133: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex
  KD-134: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex
  KD-135: [CLOSED-WITH-RECEIPT] lib/smalt/arm_gateway/router.ex, lib/smalt/data_plane/blob_storage.ex, lib/smalt/egress_router.ex
  KD-137: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-139: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-14: [CLOSED-SIMULATED] lib/smalt/data_plane/key_vault_actions.ex
  KD-140: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-141: [CLOSED-SIMULATED] lib/smalt/data_plane/blob_storage.ex
  KD-142: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-143: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-144: [CLOSED-WITH-EVIDENCE] lib/smalt/data_plane/blob_service.ex
  KD-145: [CLOSED-WITH-EVIDENCE] lib/smalt/egress_router.ex
  KD-146: [CLOSED-WITH-EVIDENCE] lib/smalt/data_plane/blob_storage.ex
  KD-147: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-148: [CLOSED-SIMULATED] lib/smalt/data_plane/cosmos.ex
  KD-149: [CLOSED-SIMULATED] lib/smalt/egress/KvRoutes.ex
  KD-15: [CLOSED-WITH-RECEIPT] lib/smalt/auth/bearer.ex, lib/smalt/egress_router.ex
  KD-150: [CLOSED-SIMULATED] lib/smalt/egress/KvRoutes.ex
  KD-151: [CLOSED-SIMULATED] lib/smalt/egress/KvRoutes.ex
  KD-152: [CLOSED-SIMULATED] lib/smalt/data_plane/queue_storage.ex
  KD-155: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex, lib/smalt/messaging/amqp/atom_bridge.ex
  KD-156: [CLOSED-SIMULATED] lib/smalt/graphlaw/validator.ex
  KD-157: [CLOSED-SIMULATED] lib/smalt/tls.ex
  KD-16: [CLOSED-SIMULATED] lib/smalt/egress/KvRoutes.ex
  KD-17: [CLOSED-SIMULATED] lib/smalt/egress/KvRoutes.ex
  KD-18: [CLOSED-with-receipt] lib/smalt/messaging/amqp/connection.ex
  KD-19: [CLOSED-with-receipt] lib/smalt/messaging/amqp/connection.ex
  KD-20: [CLOSED-with-receipt] lib/smalt/messaging/amqp/connection.ex
  KD-21: [CLOSED-with-receipt] lib/smalt/messaging/amqp/connection.ex
  KD-22: [CLOSED-SIMULATED] lib/smalt/data_plane/sentinel.ex
  KD-23: [] lib/smalt/data_plane/kql.ex, lib/smalt/data_plane/resource_graph.ex
  KD-28: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-33: [CLOSED-SIMULATED] lib/smalt/egress/KvRoutes.ex
  KD-34: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-36: [CLOSED-SIMULATED] lib/smalt/data_plane/cosmos.ex
  KD-44: [CLOSED-SIMULATED] lib/smalt/data_plane/cosmos.ex
  KD-45: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex
  KD-46: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex
  KD-49: [CLOSED-with-receipt] lib/smalt/messaging/amqp/connection.ex
  KD-51: [CLOSED-SIMULATED] lib/smalt/application.ex, lib/smalt/arm_gateway/router.ex, lib/smalt/messaging/amqp/atom_bridge.ex
  KD-52: [CLOSED] lib/smalt/data_plane/blob_storage.ex, lib/smalt/data_plane/cosmos.ex
  KD-53: [CLOSED-SIMULATED] lib/smalt/egress/AppConfigRoutes.ex, lib/smalt/egress/KvRoutes.ex, lib/smalt/egress_router.ex, lib/smalt/messaging/event_hubs.ex
  KD-54: [CLOSED-SIMULATED] lib/smalt/application.ex
  KD-55: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-56: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-57: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-58: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-59: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-60: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-61: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-62: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-64: [CLOSED-SIMULATED] lib/smalt/data_plane/cosmos.ex, lib/smalt/egress/CosmosRoutes.ex
  KD-65: [CLOSED-SIMULATED] lib/smalt/data_plane/cosmos.ex
  KD-66: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-67: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-68: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex
  KD-69: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex
  KD-70: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex
  KD-71: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex
  KD-75: [CLOSED-WITH-RECEIPT] lib/smalt/egress/KvRoutes.ex
  KD-76: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex
  KD-77: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/connection.ex, lib/smalt/messaging/amqp/frame_codec.ex
  KD-80: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-81: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-82: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-85: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/delivery_encoder.ex
  KD-86: [CLOSED-WITH-RECEIPT] lib/smalt/arm_gateway/router.ex, lib/smalt/messaging/amqp/connection.ex, lib/smalt/messaging/amqp/queue_store.ex
  KD-87: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex, lib/smalt/auth/bearer.ex
  KD-89: [CLOSED-WITH-RECEIPT] lib/smalt/trust_profile/trust_profile.ex
  KD-91: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-92: [CLOSED-SIMULATED] lib/smalt/arm_gateway/router.ex
  KD-93: [CLOSED-WITH-EVIDENCE] lib/smalt/data_plane/cosmos.ex
  KD-94: [CLOSED-SIMULATED] lib/smalt/auth/bearer.ex
  KD-97: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-99: [CLOSED-SIMULATED] lib/smalt/auth/sts_key.ex

FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 0
```

exit 0

Captured verbatim to /tmp/bk93_kdflip.txt at run time; exit code 0.

### `just docs-dod-check`

```text
#!/usr/bin/env bash
set -euo pipefail
# DOCS_ROOT is unreliable: under `import`, justfile_directory() is the
# repo root so parent_directory() overshoots; under `just -f
# justfile.d/...` it is justfile.d. Anchor on the git toplevel of the
# actual working directory, falling back to a downward search from
# DOCS_ROOT.
root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [ -z "$root" ]; then
    probe="/Users/sac"
    while [ "$probe" != "/" ] && [ ! -e "$probe/docs/jira" ]; do
        probe="$(dirname "$probe")"
    done
    root="$probe"
fi
rc=0
check() {
    if [ -e "$root/$1" ]; then
        echo "OK    $1"
    else
        echo "MISS  $1"
        rc=1
    fi
}
# Receipts cited by README/DEV_LOOP/CHANGELOG (v26.10.14 fan-out).
check docs/jira/v26.10.14/receipts/ws-12-e2e.md
check docs/jira/v26.10.14/receipts/cli-08-gates.md
check docs/jira/v26.10.14/receipts/08-servicebus-census.md
check docs/jira/v26.10.14/receipts/12-gate-closure.md
# Surfaces the docs name.
check workspace/README.md
check workspace/ARCHITECTURE.md
check smalt-cli/README.md
check smalt-cli/GATES.md
# test/enclave-testbed/README.md check retired (subject deleted at 64f6099).
# Diátaxis tree (v26.10.16 docs restructure, docs/jira/v26.10.16/
# docs-restructure-plan.md). Pinned to the landed set.
check docs/tutorials/enclave-lifecycle.md
check docs/how-to/dev-loop.md
check docs/how-to/how-to-clean.md
check docs/how-to/how-to-debug-agent.md
check docs/how-to/how-to-develop-native.md
check docs/how-to/how-to-run-wire-parity.md
check docs/reference/just-recipes.md
check docs/explanation/architecture.md
check docs/explanation/cascade-teardown.md
check docs/explanation/semantic-kernel-roadmap.md
check docs/explanation/two-tier-enclave.md
check docs/explanation/zero-drift-model.md
check docs/archive/README.md
check docs/how-to/how-to-verify-pqc-seals.md
check docs/reference/reference-affidavit-wasm.md
check docs/reference/kd-register.md
check docs/reference/ports-and-planes.md
check docs/reference/arm-gateway.md
check docs/reference/ets-tables.md
# v26.10.18 docs-audit D15: Diataxis gap pages.
check docs/tutorials/planes-profiles.md
check docs/how-to/how-to-run-burn.md
check docs/how-to/how-to-write-tests.md
check docs/how-to/how-to-add-config-key.md
check docs/reference/test-isolation-law.md
check docs/reference/burn-receipt-schema.md
# v26.10.18 HAVE-10: supervisory-engine runbook.
check docs/reference/have-runbook.md
check docs/explanation/no-sleep.md
check docs/explanation/affidavit-evidentiary-design.md
check docs/WIRE_PARITY.md
check docs/TERRAFORM_TRUST.md
# Receipts cited by the v26.10.16 user-facing docs (CHANGELOG 26.10.16,
# docs/RELEASE_NOTES_v26.10.16.md).
check docs/jira/v26.10.14/receipts/dod-07-court-x2.md
check docs/jira/v26.10.14/receipts/2026-10-15-kd53-eh-batch-witness.md
check docs/jira/v26.10.16/receipts/INDEX.md
check docs/jira/v26.10.16/receipts/r141-eh-batch-body-discriminator.md
check docs/jira/v26.10.16/receipts/cap-ingestion-functor.md
check docs/jira/v26.10.16/receipts/r178e-census-replay-repair.md
check docs/jira/v26.10.16/receipts/r119-r123-arm-list-store-reseed.md
check docs/jira/v26.10.16/receipts/r200a-kd70-delivery-annotations.md
check docs/jira/v26.10.16/receipts/r200b-kd71-xopt-props.md
check docs/jira/v26.10.16/receipts/r200d-kd68-selector-impl.md
check docs/jira/v26.10.16/receipts/r200f-kd46-mgmt-surface.md
check docs/jira/v26.10.16/receipts/r200h-kd76-pk-witness-repair.md
# Milestone wrap artifacts the docs name.
check docs/jira/v26.10.16/FINAL.md
check docs/jira/v26.10.16/RECEIPTS.md
check docs/jira/v26.10.16/WRAP_LEDGER.md
check docs/jira/v26.10.16/PUBLISH_RECORD.md
check docs/jira/v26.10.16/KNOWN_DIVERGENCES.md
check docs/RELEASE_NOTES_v26.10.16.md
# v26.10.18 wrap artifacts (FINAL.md cites only receipts/ paths that exist).
check docs/jira/v26.10.18/FINAL.md
check docs/jira/v26.10.18/RECEIPTS.md
# v26.10.17 active window (gate closed TYPED-RED, r241: no wrap artifacts
# FINAL.md/WRAP_LEDGER.md yet — version stays 26.10.16; receipts ledger exists).
check docs/jira/v26.10.17/receipts/r241-court-x2-attempt3-typed-red.md
check docs/jira/v26.10.17/RECEIPTS.md
# Front door.
check README.md
exit $rc
OK    docs/jira/v26.10.14/receipts/ws-12-e2e.md
OK    docs/jira/v26.10.14/receipts/cli-08-gates.md
OK    docs/jira/v26.10.14/receipts/08-servicebus-census.md
OK    docs/jira/v26.10.14/receipts/12-gate-closure.md
OK    workspace/README.md
OK    workspace/ARCHITECTURE.md
OK    smalt-cli/README.md
OK    smalt-cli/GATES.md
OK    docs/tutorials/enclave-lifecycle.md
OK    docs/how-to/dev-loop.md
OK    docs/how-to/how-to-clean.md
OK    docs/how-to/how-to-debug-agent.md
OK    docs/how-to/how-to-develop-native.md
OK    docs/how-to/how-to-run-wire-parity.md
OK    docs/reference/just-recipes.md
OK    docs/explanation/architecture.md
OK    docs/explanation/cascade-teardown.md
OK    docs/explanation/semantic-kernel-roadmap.md
OK    docs/explanation/two-tier-enclave.md
OK    docs/explanation/zero-drift-model.md
OK    docs/archive/README.md
OK    docs/how-to/how-to-verify-pqc-seals.md
OK    docs/reference/reference-affidavit-wasm.md
OK    docs/reference/kd-register.md
OK    docs/reference/ports-and-planes.md
OK    docs/reference/arm-gateway.md
OK    docs/reference/ets-tables.md
OK    docs/tutorials/planes-profiles.md
OK    docs/how-to/how-to-run-burn.md
OK    docs/how-to/how-to-write-tests.md
OK    docs/how-to/how-to-add-config-key.md
OK    docs/reference/test-isolation-law.md
OK    docs/reference/burn-receipt-schema.md
OK    docs/reference/have-runbook.md
OK    docs/explanation/no-sleep.md
OK    docs/explanation/affidavit-evidentiary-design.md
OK    docs/WIRE_PARITY.md
OK    docs/TERRAFORM_TRUST.md
OK    docs/jira/v26.10.14/receipts/dod-07-court-x2.md
OK    docs/jira/v26.10.14/receipts/2026-10-15-kd53-eh-batch-witness.md
OK    docs/jira/v26.10.16/receipts/INDEX.md
OK    docs/jira/v26.10.16/receipts/r141-eh-batch-body-discriminator.md
OK    docs/jira/v26.10.16/receipts/cap-ingestion-functor.md
OK    docs/jira/v26.10.16/receipts/r178e-census-replay-repair.md
OK    docs/jira/v26.10.16/receipts/r119-r123-arm-list-store-reseed.md
OK    docs/jira/v26.10.16/receipts/r200a-kd70-delivery-annotations.md
OK    docs/jira/v26.10.16/receipts/r200b-kd71-xopt-props.md
OK    docs/jira/v26.10.16/receipts/r200d-kd68-selector-impl.md
OK    docs/jira/v26.10.16/receipts/r200f-kd46-mgmt-surface.md
OK    docs/jira/v26.10.16/receipts/r200h-kd76-pk-witness-repair.md
OK    docs/jira/v26.10.16/FINAL.md
OK    docs/jira/v26.10.16/RECEIPTS.md
OK    docs/jira/v26.10.16/WRAP_LEDGER.md
OK    docs/jira/v26.10.16/PUBLISH_RECORD.md
OK    docs/jira/v26.10.16/KNOWN_DIVERGENCES.md
OK    docs/RELEASE_NOTES_v26.10.16.md
OK    docs/jira/v26.10.18/FINAL.md
OK    docs/jira/v26.10.18/RECEIPTS.md
OK    docs/jira/v26.10.17/receipts/r241-court-x2-attempt3-typed-red.md
OK    docs/jira/v26.10.17/RECEIPTS.md
OK    README.md
```

exit 0

## Falsifier

A KD-164 row appearing in a `KNOWN_DIVERGENCES.md` under `docs/jira/` after
this receipt's timestamp, or kd_flip reporting FLIP-ELIGIBLE/FLIP-PENDING-WITNESS
> 0 on the canonical register.
