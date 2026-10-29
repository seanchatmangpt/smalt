# X3 — Service Bus TOPIC publish/subscribe loop (real wire, Chicago)

**Standing:** **ALIVE** (walk + 3 Chicago tests, real wire, real substrate)

Context: solo

Date: 2026-10-20

## Subject

- `popcorn_demo/lib/popcorn_demo/live_topic.ex` (new, lane X3 owned)
- `popcorn_demo/test/live_topic_test.exs` (new, lane X3 owned)

## What the walk proves (real wire end to end)

1. ARM face on the lane substrate (rules-walk shapes from `PopcornDemo.LiveRules`,
   incl. the LRO POLL-STEP `# SLEEP-CLASS: POLL-STEP` delayMs poll): mint STS →
   ensure RG `popcorn-rg` → namespace `popcorn-ns` → run-unique topic
   `popcorn-tx-<ms>-<rand>` → subscription `popcorn-sx` (ARM PUT 200/201,
   materializes `<topic>/Subscriptions/popcorn-sx` in `:smalt_sb_queues`).
2. CBS SAS auth over the real AMQP 1.0 wire: attach `$cbs` sender+receiver
   (handles 3/2), two real `put-token` RPCs (app-props operation/type/name,
   body = SAS token string, skn `RootManageSharedAccessKey`) —
   both answered **200 LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY**.
3. Publish 2 uniquely-tagged messages to the topic entity (sender at bare
   `<topic>`), each awaiting its broker accepted-disposition.
4. Receive on `<topic>/Subscriptions/popcorn-sx`, assert BOTH messages arrive
   BYTE-EXACT in publish order (FIFO), settle each with an accepted disposition
   (receiver role, broker delivery-id echo), then re-credit and prove the
   subscription receives to EMPTY (settlement proof).

## Real command output (test tier)

```
$ cd popcorn_demo && SMALT_SB_SHARED_KEY=<per-host dev key> X3_SB_AMQP_PORT=39900 \
  X3_ARM_PORT=39902 MIX_BUILD_ROOT=_build-x3 mix test test/live_topic_test.exs
Finished in 6.1 seconds (0.00s async, 6.1s sync)
Result: 3 passed
```

Skip contract (same suite): with `SMALT_SB_SHARED_KEY` unset the suite answers
`Result: 0 tests, 3 skipped` with a loud stderr reason
(`SKIP: SMALT_SB_SHARED_KEY unset - SB CBS SAS cannot authenticate`) — never a fake pass.

Walk fragment (smoke, same env): `{:ok, "topic=OK(popcorn-tx-1792563726564-139346:2-delivered)"}`

Broker-side witness (b90 log): two `[amqp-cbs] put-token status=200
desc=LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY` per run.

## Environment (disclosed substrate divergence)

The SHARED canonical substrate (5672/9443) cannot serve this face today:
its boot path (`scripts/substrate.sh`) sets app env `:sb_shared_key =
"ws8sharedkey"` (12 bytes, below `SasVerifier`'s 32-byte floor), so
`SasVerifier.shared_key/0` falls through to a RANDOM per-boot dev key —
no client can ever mint a valid SAS. Witnessed: anonymous attaches and
put-tokens both refused with unauthorized detach/401 (the 21:26 w13-sess
put-token in the shared log also got 401 INVALID_LOCAL_SAS). The lane
therefore booted a PRIVATE substrate block with a known key via the
standard lane machinery:

```
$ SMALT_SB_SHARED_KEY=<per-host dev key> MIX_BUILD_ROOT=_build-x3 \
  scripts/substrate-ctl up --block b90 --auth enforce
{"block": "b90", "ports": [39900..39905], "pid": 35148, "reused": false, ...}
```

Shared substrate untouched. **Coordinator actions suggested** (not done —
outside lane ownership):

- KD candidate A: shared-substrate SB SAS is unusable (env key under the
  32-byte floor → random fallback → every CBS put-token 401s). Close condition:
  `scripts/substrate.sh` pins a >=32-byte key (e.g. the dev_env per-host key)
  so canonical-port lanes can authenticate.
- KD candidate B: `PrimitiveCodec` fails `{:error, :truncated}` decoding
  map32 (0xD1) at both size semantics (probed directly, 2026-10-20); map8
  (0xC1, size+1) decodes fine. Client legs must use map8 until fixed.
- KD candidate C: broker `flow` field order is
  `[next_incoming_id, incoming_window, next_outgoing_id, outgoing_window,
  handle, delivery_count, link_credit, ...]` (non-standard; spec is
  next-outgoing-first). Spec-ordered flows leave credit nil and receivers
  starve (witnessed drain timeout, zero deliveries). Clients must send
  broker-order flows; a real rhea/SDK census would flag this if it is a
  divergence rather than an internal-only shape.

## Wire shapes this leg pins (for future SDK census)

- flow frame in broker field order (see KD candidate C)
- application-properties as map8 with str8 keys
- put-token: app-props operation/type/name, body = SAS token string,
  string-to-sign = `URL-ENCODED sr + "\n" + se` (decoded-sr signing 401s —
  mirrors SasVerifier.ex:62 comment)
- `$cbs` reply arrives on the cbs RECEIVER link; broker requires a client
  cbs-receiver attach before answering (find_reply_link kind :cbs role :sender)
- subscription receiver address: `<topic>/Subscriptions/<sub>` (bare entity)
- settle: disposition role=true, settled=true, state accepted (0x24), ids =
  the BROKER's outbound delivery-ids read off each transfer performative

## Failures observed and fixed during the leg (honest log)

- recv :closed ×2 phases: unauthorized detaches (missing CBS claim) — fixed
  with real put-token
- broker GenServer crash: `KeyError :application_properties` — my app-props
  map32 failed decode → `decode_message_sections` returned `%{}`; fixed
  client-side with map8 (server crash on undecodable wire remains a broker
  robustness defect worth a gate)
- `recv::timeout` zero-delivery: spec-ordered flow starved — fixed with
  broker-ordered flow
- enc_elem FunctionClauseError: pre-encoded nested accepted-state iodata —
  fixed with a pass-through clause
- settle_all returned `{:ok, st}` vs chain `:ok` — fixed

No failures remain: last full run 3/3 pass, walk OK.
