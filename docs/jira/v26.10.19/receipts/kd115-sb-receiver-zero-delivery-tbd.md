# Receipt — KD-115 SB plain-queue receiver zero-delivery on flow credit

Standing: **UNKNOWN** (evidence skeleton, TBD; witnessed FAIL, no fix)
Context: full
Lane: kd-registrar; no lib/ edits.

## Divergence

On the plain (non-session) Service Bus queue, the receiver link performs the
full handshake (attach, flow credit, CBS, SAS 200) and the sender's send
resolves — but no delivery is ever produced on flow credit. The wire is
send-side only; receive is unexercisable over the official SDK.

## Witnessed evidence (verbatim from the wf receipt)

`docs/jira/v26.10.19/sdk-results/wf3-ts-messaging-eventing.md`
(SUBJECT_SHA b847c020ee6b0a7ef426e27379f960228932feb0, 2026-10-19):

```
[FAIL] sb-send20-receive-complete — received=0/20 fifo=true —
receiver-delivery gap: attach+flow+CBS succeed and send resolves, but no
delivery is produced on receiver-link flow credit (send-side only on the wire)
[FAIL] sb-message-lock-lost — no delivery — receiver-delivery gap leaves the
lock-expiry leg unexercisable over the SDK
[FAIL] sb-dlq-maxdelivery — DLQ size=0 reason=null
```

Downstream starvation: message-lock and DLQ max-delivery legs fail only
because zero deliveries occur — one root cause, three FAIL cells.
Sessions DO deliver (see KD-116) — the gap is plain-queue receiver dispatch.

## Close condition / falsifier

Plain-queue receiver produces deliveries on flow credit. Falsifier:
`sb-send20-receive-complete` cell GREEN — send 20 → receive 20/20 →
complete, over the official `@azure/service-bus` SDK.
