# w6v2 — KD-112 flip confirmation

**Standing:** ALIVE (confirmation-only; no double-flip)

## What this receipt covers

w6v landed the `# KD-COVERS: KD-112` token (router.ex:5579) but its
`kd_flip --apply` refused on witness-mtime ordering. This lane re-witnessed
post-token and confirmed the flip state.

## Real output

Post-token re-witness (`MIX_BUILD_ROOT=_build-lane-w6v2 MIX_ENV=test mix run
--no-start tmp/w6v_verify.exs`, exit 0, first green window after the w6R
router split):

```
PUT_INITIATIVE_OK id=/subscriptions/w6v-1792508891919/providers/Microsoft.Authorization/policySetDefinitions/w6v-init-1
GET_ECHO_OK name=w6v-init-1
LIST_COUNT=1
```

Addendum appended to the evidence receipt
(docs/jira/v26.10.19/receipts/kd112-arm-policy-initiatives-tbd.md).

`python3 scripts/kd_flip.py --apply` → `FLIP-ELIGIBLE: 0,
FLIP-PENDING-WITNESS: 0 — nothing FLIP-ELIGIBLE; register unchanged`.
KD-112 row already CLOSED-SIMULATED (flipped by w6u's earlier --apply pass,
which postdated the token). Confirmation only — no double-flip.

## Falsifier

Re-run `tmp/w6v_verify.exs` on the quiesced tree; a red run with the row
still CLOSED-SIMULATED would be vacuous.

## Disclosures

Probe-side body fix: `policy_definitions` → `properties.policyDefinitions`
(non-empty, members with `policyDefinitionId`) — witness script only, surface
unchanged. No mocks, no Process.sleep (bounded poll ~2.5 min through w6R's
split churn to the first green window).
