# BK-B4RC — BK-B4R send-gate regression court

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-B4RC
- Input: `docs/jira/v26.10.22/receipts/bkb4r-sender-link.md` (the fix being
  pinned); KD-86 row (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — CLOSED
  2026-10-21, BK-27)

## What this lane pinned

BK-B4R fixed the KD-86 send-gate hole: `ensure_entity/1`
(`lib/smalt/messaging/amqp/queue_store.ex`) consulted only `:smalt_sb_queues`,
refusing every send to a management-plane-created entity (ARM gateway PUT /
ATOM alias — record in `:smalt_resources`, no `:smalt_sb_queues` row) with
`{:error, :messaging_entity_not_found}` → sender-link DETACH
MessagingEntityNotFound. This lane adds the regression court and proves the
fix non-vacuously. No `lib/` changes by this lane.

## Court

`test/internal/b4rc_send_gate_court_test.exs` — 3 legs, Chicago (real
collaborators, no mocks, no sleeps):

- **Leg A (the fix)**: real flat-ATOM management PUT through
  `Smalt.Amqp.AtomBridge.handle_request/3` — the exact dispatcher the wire
  request lands on (`ArmGateway.Router` `sb_atom_alias` → `AtomBridge`,
  same face the b4 harness's `PUT http://127.0.0.1:$ARM/<queue>` hits) —
  creates the entity; assert `queue_info` is still `:error` (the exact
  BK-B4R hole: record in `:smalt_resources`, no AMQP row); real send through
  the KD-86 gate (`QueueStore.enqueue/3`, the face connection.ex ingest
  calls); assert the gate materialized the row and a real
  `dequeue_matching/2` claim delivers the intact body.
- **Leg B (KD-86 original intent)**: flag off (default) → send to a
  never-created queue answers `{:error, :messaging_entity_not_found}`, no
  silent creation.
- **Leg C (KD-86 original intent)**: flag on → auto-create-on-send restored.

## Embedded court output

```
MIX_BUILD_ROOT=_build-bkb4rc MIX_ENV=test mix test test/internal/b4rc_send_gate_court_test.exs
...
Finished in 0.03 seconds (0.00s async, 0.03s sync)
Result: 3 passed
```

## Falsifier (shim court, non-vacuity)

Mutation: neutralize `ensure_entity/1`'s ARM arm (`arm_entity?(name) ->
ensure_queue(name)` replaced by `false -> ensure_queue(name) # SHIM-COURT`
in `lib/smalt/messaging/amqp/queue_store.ex`), rerun the court:

```
BASELINE sha256(queue_store.ex) a2cc304f76e6f2138e6586be804f2494f2e8dc8314d152b2efcd1fbb6a5013ef
Result: 2/3 passed
Failed: 1 test
stacktrace: test/internal/b4rc_send_gate_court_test.exs:60: (test)
```

Line 60 is Leg A's `assert {:ok, _seq} = QueueStore.enqueue(...)` — the send
leg flips to the pre-fix refusal exactly as the falsifier demands, while the
KD-86 pin legs stay green. RESTORE: byte-exact, sha256 unchanged
(`a2cc304f…13ef`), RESTORE-OK. A court that cannot flip is FAIL; this one
flips.

## Fresh runs (post-restore, real gates)

```
mix test b4rc_send_gate_court_test.exs bk27_kd86_auto_ensure_gate_test.exs \
         kd115_credit_first_delivery_test.exs wire_exp4_court_test.exs
Result: 18 passed

mix test kd51_sb_atom_https_test.exs kd156_sb_shape_test.exs \
         bk87_arm_delete_purge_test.exs t27lq_list_queues_feed_test.exs
Result: 17 passed
```

(kd115's wire-probe leg included — node present, probe ran.)

## Files committed (explicit paths)

- test/internal/b4rc_send_gate_court_test.exs
- docs/jira/v26.10.22/receipts/bkb4rc-send-gate-court.md (this receipt)

## Standing

ALIVE — fix pinned by a flipping regression court on the real management +
send faces; KD-86 original semantics re-pinned; falsifier witnessed.
