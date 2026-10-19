# G1 Queue Storage — Feasibility Scoping (v26.10.19)

## 1. What exists today

**No Azure Queue Storage REST surface exists.** Verified by grep across `lib/` and `test/`: zero hits for `PopReceipt`, `popreceipt`, `visibilitytimeout`, `azqueue`, or a `/{account}/messages` route family. `lib/smalt/data_plane/` contains only blob/cosmos/vault/kql/sentinel/atlas/resource_graph/purview planes.

What *does* exist and is reusable is the Service Bus **AMQP** stack, a different surface:
- `lib/smalt/messaging/amqp/queue_store.ex` — `:smalt_sb_queues` / `:smalt_sb_messages` via `Smalt.Store`, `complete/1`, `release/2`, `defer/3`.
- `lib/smalt/messaging/amqp/lock_manager.ex` — peek-lock semantics (`locked_until`).
- `lib/smalt/enclave/state.ex` — queue lifecycle / cascade delete.
- WIRE_PARITY rows confirm SB is AMQP-wire-tier only; no HTTP queue egress routes.

`lib/smalt/egress_router.ex` registers no queue routes — blob (guarded catch-all `/{account}/{container}[/{blob}]` with `@blob_put_comps`/`@blob_get_comps` whitelists) and Cosmos (`with_route` pattern).

**Scoping conflict**: Queue Storage's REST namespace (`https://{account}.queue.core.windows.net/{queue}/messages`) collides with the blob catch-all splat at the same `/{account}/...` prefix. The router needs a disambiguation arm before the blob splat (query-shape detection `restype=queue` / `comp=list`, or an explicit queue-path guard mirroring the `@blob_get_comps` discipline).

## 2. What the G1 test needs

Put Messages (`POST /{queue}/messages`), Get Messages with `visibilitytimeout` + `numofmessages`, popreceipt issuance, Update/Delete Message with `popreceipt` (incl. **stale-replay**: second update/delete with expired/superseded popreceipt answers 404 `PopReceiptMismatch` / `MessageNotFound`), Dequeue visibility re-appearance.

## 3. Effort sketch

- **New module**: `lib/smalt/data_plane/queue_storage.ex` modeled on `blob_storage.ex`/`cosmos.ex` (pure Store-backed, wire-agnostic, `{:ok, status, headers, body}`).
- **Routes**: dispatch block in `egress_router.ex` before the blob splat: `POST/GET/DELETE /{account}/{queue}/messages[/{msg_id}?popreceipt=...]`, `PUT .../{msg_id}?popreceipt=...`, `PUT /{account}/{queue}?restype=queue`, `DELETE` queue, `GET ...?comp=list`. Typed error envelope in the blob `x-ms-error-code` style (KD-04 precedent).
- **StoreTables**: `:smalt_q_queues` + `:smalt_q_messages` rows (do NOT reuse `:smalt_sb_*` — different lock model: popreceipt + visibility_timeout vs AMQP lock token). Mirror the `:smalt_sb_messages` row shape; register in `@tables` + sweep lists. Regenerate via `mix smalt.gen`.
- **Tests**: `test/data_plane/queue_storage_test.exs` + wire pins in `test/wire/egress_wire_test.exs` + G1 azsim harness in `test/azsim/`.

Size: ~400-600 line module + router arm + 2 rows + 1-2 test files — a mid-size lane, not G4-scale.

## 4. KD/GAP law

**No GAP token is required, and lanes must not mint one.** G1 is absent (no WIRE_PARITY row), so no token attaches. Sequence: lane lands the surface + its WIRE_PARITY row; the **coordinator** mints GAP tokens afterward for residual divergences (KD-04 precedent: code in-lane, token flipped by coordinator witness).
