# BK-EXW2 — EXPL12-W handshake × BK-B4R send-gate compose verification (read-only verify lane)

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-EXW2
- Inputs: `docs/jira/v26.10.22/receipts/expl12w-arm-handshake.md` (the
  handshake under verification) · `docs/jira/v26.10.22/receipts/bkb4rc-send-gate-court.md`
  (the send-gate court re-run fresh) · KD-86 row (CLOSED 2026-10-21, BK-27)
- Scope: **read-only verify lane** — no `lib/`, `smalt-cli/smalt_cli/`, or
  test edits. Only this receipt was written (plus throwaway /tmp scratch).

## What this lane verified

That EXPL12-W's KD-15 tokenless-first ARM handshake (`wire.arm_request`) and
BK-B4R's `queue_store.ex ensure_entity/1` send-gate fix — two different
surfaces riding the same substrate — compose on current HEAD.

## Leg 1 — ty courts fresh on HEAD

`smalt-cli/.venv-cli/bin/python -m pytest tests/test_ty_arm_handshake.py
tests/test_ty_deployment.py -m enforce` (SMALT_CLI_LANE=bkexw2, lane-private
substrate):

```
.......  [100%]
7 passed in 6.30s
```

`-m "not enforce"` session: `7 deselected in 0.11s` — both files are
fully enforce-marked, so the anonymous session has no population (noted,
not a failure).

## Leg 2 — B4R send-gate court fresh on HEAD

```
MIX_BUILD_ROOT=_build-bkexw2 MIX_ENV=test mix test test/internal/b4rc_send_gate_court_test.exs
...
Finished in 0.1 seconds (0.00s async, 0.1s sync)
Result: 3 passed
```

## Leg 3 — live composition session (shared substrate, 9444 TLS twin)

One session, real wire traffic, real AMQP. Instrumentation wrapper over
`httpx.Client.request` records the legs (traffic itself untouched).
Env: `SMALT_ARM=https://127.0.0.1:9444`, `SSL_CERT_FILE=.smalt/tls/ca-cert.pem`
(the shared substrate's 9443 face is plain HTTP right now — the TLS twin is
the challenged face, same face EXPL12-W's witness used). Flow:
`deployment group-create` → `deployment create -p @params.json` (template
expressions `[parameters('nsName')]` / `[parameters('queueFullName')]`
materialized from the params file) → `arm_get` of the queue → real
`servicebus send`/`receive` on the ARM-created queue.

```
deployment create (with -p @params.json) -> exit 0
{
  "deployment": "bkexw2-dep-17926852472068d851b",
  "provisioningState": "Succeeded",
  "resourcesApplied": [
    "bkexw2-ns-17926852472068d851b",
    "bkexw2-ns-17926852472068d851b/bkexw2-q-17926852472068d851b"
  ]
}
arm_get queue: 200
queue read back via arm_request: name=bkexw2-q-...d851b
AMQP send+receive on ARM-created queue: OK body=bkexw2-compose-17926852472068d851b
```

Full leg trace — **every** ARM operation took the tokenless-first handshake
(challenge → STS mint → bearer retry), including the queue PUT whose record
the send-gate must materialize:

```
PUT tokenless -> 401 .../resourceGroups/bkexw2-rg-...
POST tokenless -> 200 /oauth2/v2.0/token
PUT bearer -> 201  (group created)
PUT tokenless -> 401 .../Microsoft.Resources/deployments/...
PUT bearer -> 200  (deployment create -p @params.json)
PUT tokenless -> 401 .../namespaces/bkexw2-ns-...
PUT bearer -> 202  (namespace PUT)
PUT tokenless -> 401 .../namespaces/.../queues/bkexw2-q-...
PUT bearer -> 201  (queue PUT — the send-gate's input record)
GET tokenless -> 401 .../queues/bkexw2-q-...
GET bearer -> 200  (arm_get read-back)
```

Then a real AMQP send+receive (CBS dev-key SAS, `azure-servicebus` via the
CLI) delivered the intact body on the management-plane-created queue —
exactly the KD-86 hole BK-B4R closed, exercised live rather than in-court.

## Falsifier residue (honest notes, no claim affected)

- The local deployment engine does not evaluate `concat()` in resource
  names; the nested `ns/queue` name was passed as a parameter value
  (parameter materialization itself is the surface under test). The
  ty_deployment court uses literal nested names for the same reason.
- First probe used lowercase `resourcegroups` in the read-back path and got
  RouteNotFound — the router's resource-ID matching is case-normalized
  (`resourceGroups`), consistent with the router header comment.

## Standing

**ALIVE** — handshake courts (7/7), send-gate court (3/3), and one live
session where tokenless-first ARM traffic materialized a queue that a real
AMQP sender delivered to, all on current HEAD. The two surfaces compose.
