# kd101-eg-webhook-tbd.md — evidence skeleton (kd-registrar, 2026-10-19)

- **KD row**: KD-101 (Event Grid no-HTTP-webhook)
- **Standing**: UNKNOWN (skeleton — no embedded command output yet; will be flagged SUSPECT by receipt_index until witnessed)
- **What would witness**: An Event Grid event subscription with an HTTP webhook subscriber endpoint receives a real pushed CloudEvent over the wire, including the subscription-validation handshake (WebHook-Request-Origin / WebHook-Event-Delivery-Response) — probe output shows handshake 200 then a delivered event body on the subscriber socket.
- **Falsifier**: subscriber endpoint receives the validation handshake AND a delivered CloudEvent after event publish

Pending command (exact): `just substrate-up` then run the Event Grid webhook
witness probe (subscription-validation handshake + CloudEvent push, falsifier
above) against the booted substrate — **BLOCKED during in-flight court**:
requires a substrate boot (9443/8443-class ports), forbidden while a court is
in flight. Witness lane runs it post-court and re-embeds output here.

Context: solo (registrar mint; witness run pending)
