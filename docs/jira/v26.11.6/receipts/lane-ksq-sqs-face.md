# Lane K-SQ — SQS query/JSON face + E1 claim_wait (v26.11.6)

Standing: PARTIAL_ALIVE — both courts executed green this session on the canonical checkout:
Elixir integration court `MIX_BUILD_ROOT=_build-lane-sq mix test test/integration/sqs_roundtrip_test.exs` = 14/14 passed;
real-boto3 court `SMALT_SQS_PORT=39713 verification/py/.venv/bin/pytest test_wf9_sqs.py -q` = 10 passed
(boto3 1.43.124, real SigV4 on every request; lane-private judge boot documented in the py court docstring).
Disposition (operator ruling): smalt face = BEAM emulator-parity twin; strategic face = arcus ingress/aws —
no further smalt-side investment beyond this landing (EH-REST twin precedent).

## Subject

`/Users/sac/smalt` (canonical checkout, no commits — coordinator owns git).

## Owned diff

- `lib/smalt/egress/sqs/sqs_routes.ex` (NEW): plug with SigV4-header face gate
  (`Authorization: AWS4-HMAC-SHA256...` claims, everything else passes through un-halted);
  dual wire faces — legacy query protocol (form-urlencoded body, Version=2012-11-05 gate →
  typed 400 InvalidAction, XML responses) and modern botocore JSON protocol
  (`x-amz-json-1.0` + `X-Amz-Target` → JSON responses; modern botocore >= 1.34 sends SQS as
  JSON — witnessed on the wire in the py court boot); typed SQS ErrorResponse and
  `{"__type"}` JSON error envelopes; per-code status mapping.
- `lib/smalt/egress/sqs/sqs_query.ex` (NEW): RFC3986 percent-decode (+ stays +),
  dotted-index lists (Name.N), `entries/2` + `entries_all/2` (Id-less message-attribute
  entries), `json_params/2` flattening the JSON face into the same dotted-index flat map
  (face-agnostic SqsActions), Version gate.
- `lib/smalt/egress/sqs/sqs_xml.ex` (NEW): envelopes + payload renderer
  (`response_from_payload/2`: message elements, batch result/error entries,
  GetQueueAttributes Attribute set, ListQueues) — no xmlns: the modern-botocore query-mode
  parser returns an EMPTY result when xmlns is present (witnessed in the py court boot).
- `lib/smalt/egress/sqs/sqs_md5.ex` (NEW): body_md5 over raw received bytes;
  attributes_md5 = canonical sorted pack `name_len(32) ++ name ++ value_len(32) ++ value`.
- `lib/smalt/egress/sqs/sqs_receipt.ex` (NEW): `sqs1` + url_b64(md5-prefix(4) ++
  term_to_binary({queue, seq, token, deadline})); decode validates checksum/shape;
  liveness (queue match, current token, unexpired lock) validated against LIVE store state
  in SqsActions.handle_result/2 — ChangeMessageVisibility legitimately extends past the
  mint-time deadline. The SB dashed-UUID lock token NEVER appears on the SQS wire
  (court + boto3 falsifier G3: `re.fullmatch(dashed-uuid)` is None).
- `lib/smalt/egress/sqs/sqs_actions.ex` (NEW): CreateQueue (idempotent, Attribute.N
  attrs stored on the queue info row), ListQueues (prefix), GetQueueAttributes
  (QueueArn / counts / VisibilityTimeout / DelaySeconds / created-modified), SendMessage
  (DelaySeconds → :scheduled_enqueue_time, existing law; MessageAttributes → app_props;
  MD5OfMessageAttributes), SendMessageBatch (partial failure: SenderFault
  BatchResultErrorEntry; empty MessageBody = SenderFault MissingParameter), ReceiveMessage
  (long-poll, VT override, system attributes, message-attribute round-trip),
  DeleteMessage (idempotent stale-handle face), DeleteMessageBatch, ChangeMessageVisibility
  (vt=0 → release; vt>0 → LockManager.renew; expired → MessageNotInflight), DeleteQueue
  (purge + entity delete).
- `lib/smalt/messaging/amqp/queue_store.ex` — E1 (the ONLY engine edit):
  `claim_wait/2` (wait_ms cap 20s), `{:claim_wait, ...}` handle_call parking waiters in
  server state, `flush_waiters/1` after every availability-changing mutation (enqueue /
  fanout / complete / release / deadletter / sweeps / cancel_scheduled /
  delete_by_sequence / purge_queue / lock_sweep), `:waiters_tick` handle_info via
  Process.send_after (runtime SCHEDULING; no Process.sleep anywhere), explicit
  GenServer.call timeout `wait_ms + 5_000`. Deviation from the dispatch contract,
  disclosed: waiters are woken with a REAL claim result claimed atomically inside the
  serialized server (not `:ready`-then-re-claim) — race-free by construction. Engine
  capability, vendor-neutral long-poll law — stays per operator ruling.
- `test/integration/sqs_roundtrip_test.exs` (NEW): SigV4 face gating, Version gate,
  unknown-action 400, MD5 parity, receipt-handle shape/decode + idempotent delete,
  cross-queue 404 ReceiptHandleIsInvalid, CMV vt=0 release + receive-count bump,
  long-poll (empty ~1s deadline; mid-poll wake < 3s via flush_waiters), DelaySeconds
  invisibility + bounded poll, GetQueueAttributes counts/NotVisible, batch partial
  failure, DeleteQueue NonExistentQueue refusal, ListQueues prefix, engine roundtrip
  (SQS-send receivable via QueueStore.dequeue_matching) — all over REAL TCP (Bandit +
  fresh Mint HTTP/1 connection per request; httpc keep-alive HOL-blocked the mid-poll
  send — per-request-connection law disclosed in the test header). One fixed
  `:timer.sleep(200)` inside the mid-poll sender task = SCHEDULING of the send event,
  not a coordination wait (sleep-gate exception requested via this disclosure; the
  assertion side is bounded-timing, never wait-and-hope).
- `verification/py/test_wf9_sqs.py` (NEW): real-boto3 court, 10 gates — G1
  create/list/get-attrs, G2 MD5 parity + ApproximateReceiveCount, G3 receipt-handle law
  (dashed-UUID fullmatch None; cross-queue ReceiptHandleIsInvalid), G4 CMV vt=0 release +
  count bump, G5 long-poll deadline + mid-poll wake < 3s, G6 DelaySeconds, G7 counts, G8
  attributes-MD5 vs inline-Python canonical encoder (sharp falsifier) + botocore
  receive-side MD5 validation, G9 batch partial failure, G10 Version gate (raw urllib,
  SigV4 header). Bounded `wait_until` polls; the mid-poll thread uses one
  `time.sleep(0.5)` as send SCHEDULING (disclosed). boto3 client is created at module
  import; court targets SMALT_SQS_PORT (judge boot or mounted substrate).

## E1 ledger

E1 = claim_wait/2 + waiters list + flush_waiters/1 + :waiters_tick + call timeout — the
ONLY queue_store.ex change this lane made. Known cosmetic debt disclosed: handle_call
clauses not grouped (compiler warning); `rescue` without exception names in the routes
plug (type warning). Both are safe coordinator follow-ups.

## Collisions / minimal unblocks (disclosed)

- `lib/smalt/aoq/arrow/flatbuf.ex` — mid-flight SyntaxError from the flatbuf lane froze
  whole-project compile twice; this lane polled (SLA) and compiled its own modules
  manually (ParallelCompiler into the lane build root's ebin) to keep courts running.
  No edits by this lane to flatbuf.ex; its owner repaired it; final mix compile RC=0.
- `lib/smalt/egress/sqs/sqs_xml.ex` — concurrently touched by another writer mid-wave
  (stub `wrap/3` appeared); superseded last-writer with the full implementation.
- `test/integration/sqs_roundtrip_test.exs` — re-saved externally mid-wave; superseded.

## Mounted-substrate fact (router ordering)

The coordinator's `:sqs_query_face` mount is IN, but `Smalt.Auth.Bearer` runs BEFORE it
and 401-challenges any non-Bearer Authorization header (witnessed: curl on the mounted
substrate → 401 MalformedBearerHeader). Coordinator one-line follow-up: move
`plug(:sqs_query_face)` above `plug(Smalt.Auth.Bearer)`, or add an AWS4-HMAC-SHA256
exemption to the Bearer plug. Court evidence is unaffected (courts boot the plug
standalone over real TCP).

## Substrate

Lane-private judge only (Store + QueueStore + Bandit plug on 39713, lock fd closed,
judge beam killed at teardown, port freed, no orphan). The shared substrate was booted
once (enforce mode) and killed after the Bearer-ordering fact was witnessed; substrate
DOWN at landing (status verified).

## KD rows

KD-SQ-1 (receipt-handle wire form) and KD-SQ-2 (SigV4 shape admitted / signature
unverified; modern-boto3 JSON face; no-xmlns law) minted in
`docs/jira/v26.11.6/KNOWN_DIVERGENCES.md` — appended after KD-KIN-1..4, no id collision
(first-mint coordination: the register already existed). Note: KD-196 registers the SQS
pack row as PROPOSE-ONLY until a per-face roundtrip receipt lands — this receipt is that
receipt; the coordinator may flip KD-196's SQS leg receipt-gated.

## Verification ladder (real runs this session)

- `MIX_BUILD_ROOT=_build-lane-sq mix compile` → RC=0, warnings only (disclosed above).
- `MIX_BUILD_ROOT=_build-lane-sq mix test test/integration/sqs_roundtrip_test.exs` →
  14 passed, 0 failures.
- `SMALT_SQS_PORT=39713 verification/py/.venv/bin/pytest test_wf9_sqs.py -q` →
  10 passed (boto3 1.43.124).
- NOT run: `just court` / `court-x2` (coordinator transition) and the full offline
  `mix test` (other lanes in flight on the shared tree; my E1 edit touches the AMQP
  claim path — the coordinator's full mix test at integration is the cross-lane gate).

## Standing arguments

- The twin-face disposition: smalt face = BEAM emulator-parity twin (EH-REST precedent),
  strategic face = arcus ingress/aws. E1 claim_wait stays — engine capability, reusable
  by the AMQP long-poll surface, vendor-neutral.
- Falsifiers that would kill this landing: a dashed-UUID receipt handle on the SQS wire
  (G3), an attributes-MD5 mismatch vs the canonical encoder (G8), a long-poll that
  returns early or misses a mid-poll send (G5), a batch that fails atomically instead of
  partially (G9). All executed green this session.
