# V261019-06 — Queue Storage: peek/clear comps out-of-G1-face

- **Release:** v26.10.19
- **Lane:** queue-storage (data plane)
- **Base:** HEAD `502c4ed`
- **Status:** ready-for-work
- **Source WO:** `docs/jira/v26.10.19/WORK_ORDERS.md` WO-6

## Objective

Implement the two Queue Storage comps that were deliberately deferred (not a
defect) at G1 land: peek-messages and clear-messages. Evidence:
`docs/jira/v26.10.18/receipts/i29-g1-land.md` — "Peek/clear-message comps are
NOT in the G1 face (scoping doc section 2 lists put/get/update/delete +
lifecycle only). No GAP token minted." Scoping:
`docs/jira/v26.10.18/azsim-burn/G1-QUEUE-STORAGE-SCOPING.md`.

Verified in tree on HEAD: `lib/smalt/data_plane/queue_storage.ex` has
`put_message/4` (:231), `get_messages/4` (:275), `update_message/6` (:329),
`delete_message/6` (:369), `delete_queue/3` (:112) — no peek/clear. The
egress arm `lib/smalt/egress_router.ex:138` (`queue_storage_plane`) routes
`GET /{account}/{queue}/messages` → `{:get_messages, account}` and
`DELETE /{account}/{queue}/messages` (no id) is currently un-routed, which is
exactly the clear-messages REST shape; `GET .../messages?peekonly=true` is the
peek shape. Percent-encoded queue names stay out of face per the R154
decode-aware precedent noted in the land receipt.

## Files owned

- `lib/smalt/data_plane/queue_storage.ex` (two new engine comps)
- `lib/smalt/egress_router.ex` (`queue_storage_plane` arm: peek routing on the
  existing `GET .../messages` match; new `DELETE /{account}/{queue}/messages`
  match → clear)
- `test/data_plane/queue_storage_test.exs` (or the G1 land's engine test file
  of record — follow i29-g1-land.md's 11/0 engine + 26/0 wire pattern)

## Tasks

### T1 — engine: `peek_messages/4`

`GET /{account}/{queue}/messages?peekonly=true&numofmessages=n[&visibilitytimeout is IGNORED]`

1. New `peek_messages(account, queue, opts \\ %{})` in `queue_storage.ex`,
   mirroring `get_messages/4` (`:275-...`) minus the mutation: filter
   `visible?/2`, `take(n)`, emit `<QueueMessage>` entries with
   `dequeue: false, text: true` — peek MUST NOT rotate popreceipt, bump
   `next_visible_on`, or increment `dequeue_count` (Azure semantics).
2. `numofmessages` cap follows the existing `parse_numofmessages/1` bounds;
   missing queue → 404 `QueueNotFound` (same error shape as get_messages).

### T2 — engine: `clear_messages/3`

`DELETE /{account}/{queue}/messages` (no message id)

1. New `clear_messages(account, queue)` — delete all rows under
   `key(account, queue) <> "/"` in `@messages_table` (pattern: prefix-list +
   delete per row); 204/`NoContent` with `std_headers()` per Azure; missing
   queue → 404 `QueueNotFound`.
2. Clear is immediate and unconditional — expired-but-present rows go too
   (Azure clears the whole content).

### T3 — egress arm routing

In `lib/smalt/egress_router.ex` `queue_plane_route/3`:

1. Peek: the existing `GET [account, _queue, "messages"]` match gains
   query-shape disambiguation — `qp["peekonly"] == "true"` →
   `{:peek_messages, account}`, else `{:get_messages, account}` (keeps the
   arm's existing query-shape contract; nothing else changes for get).
2. Clear: `DELETE [account, _queue, "messages"]` — currently matched only as
   4-element path (`messages` + id). Add the 3-element
   `DELETE [account, _queue, "messages"]` → `{:clear_messages, account}`
   BEFORE/more-specifically-than any splat; the 4-element delete stays
   `{:delete_message, account}` unchanged.
3. Wire both through `queue_dispatch` mirroring the `:get_messages` arm
   (`{:ok, status, headers, body}` → XML response with
   `put_resp_content_type("application/xml")`; errors via `blob_error`).
4. Byte-identity invariant: every non-queue request still `:pass`es unchanged
   to the blob splat/Cosmos/KV — assert this in the wire test with a
   blob-shaped control request per arm change.

### T4 — tests (engine + wire)

1. Engine: peek returns visible messages with `DequeueCount` unchanged and no
   popreceipt rotation (a subsequent `get_messages` still sees
   `dequeue_count` as it was); `numofmessages` cap; `QueueNotFound`.
   Clear empties the queue and a following `get_messages` returns an empty
   list; `QueueNotFound`.
2. Wire: `GET .../messages?peekonly=true` → 200 XML peek body;
   `DELETE .../messages` → 204; `DELETE .../messages/{id}` still hits
   delete_message; blob-shaped control requests unaffected.
3. Follow the i29-g1-land.md pattern: engine green + wire green, no GAP token
   unless a parity defect vs real Azure semantics is witnessed.

## Acceptance falsifiers

- [ ] Wire peek test MUST fail on the pre-T3 router (peekonly=true currently
      falls into `{:get_messages, ...}` and mutates rows — the response body
      will differ and `dequeue_count` increments: that mutation witness is the
      red state).
- [ ] Wire clear test MUST fail pre-T3 (3-element DELETE is un-routed →
      falls through to the blob splat / 404 catch-all, not 204).
- [ ] Peek mutation-freedom test: after peek, `get_messages` reports the same
      `DequeueCount` and the same messages remain visible immediately (no
      visibilitytimeout applied).
- [ ] Byte-identity control: non-queue requests (blob get, Cosmos, KV) produce
      byte-identical responses before and after the router change.
- [ ] `mix test <engine test> <wire test>` green; no GAP token minted unless a
      real-Azure parity defect is witnessed (per the WO close condition).
- [ ] Percent-encoded queue names remain out of face (R154 precedent): a
      percent-encoded queue-name request is NOT claimed by the queue arm.
