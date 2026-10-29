# EXPL-4 — Wire-Protocol Front-Ends ERRC Sweep (read-only)

**Standing: PARTIAL_ALIVE** — findings executed as read-only probes against the real
compiled modules; no repairs implemented (explorer lane). Repair tickets below are for
dispatch, not landed work. `Context: solo`

Scope: `lib/smalt/messaging/kafka/`, `lib/smalt/messaging/amqp10/`,
`lib/smalt/webpubsub/`, `lib/smalt/messaging/amqp/` (four wire front-ends).
Excluded covered findings: BK-58/65/66/87/103/103b/116/117b, spofb-eh-atom, KD-166/167.

## Findings (ranked)

### F1 (top ticket) — Web PubSub token verify is fail-open on ABSENT claims (W1 class, WITNESSED)

`lib/smalt/webpubsub/token.ex` `verify/2` builds its Joken config with `aud`/`nbf`/`exp`
validators, but Joken SKIPS validation for any claim absent from the token. Witnessed by
real probe against the compiled module (dev key):

```
Token signed with %{"webpubsub.role" => ["webpubsub.sendToGroup"]} — no aud, no exp,
no nbf, no sub:
=> {:ok, "", ["webpubsub.sendToGroup"]}  # ADMITTED to any hub, never expires
```

A token with no `aud` is valid for ANY hub (cross-hub token reuse), a token with no
`exp` never expires, and `claims["sub"] || ""` admits an empty-string principal. The
mint side always sets the claims, so this only bites on hand-crafted/minted-elsewhere
tokens — exactly the hostile-token case verify exists for. Fail-open asymmetry: present
claims are validated (cross-hub and expired tokens ARE refused when the claims exist),
absent claims are not.

**Ticket WPS-EXP4-1 (repair):** in `Token.verify/2` (or `build_config/1`), require
`aud`/`exp`/`nbf`/`sub` presence (Joken `:essential` or a presence guard before
verify), and refuse empty `sub`. Falsifier: a no-aud/no-exp token must verify to
`:error`; a hub-A token must be refused on hub B.

### F2 — AMQP 1.0 FrameDecoder raises untyped MatchError on remote input (WITNESSED)

`lib/smalt/messaging/amqp10/frame_decoder.ex` moduledoc claims "decode never raises on
remote input", but every sized element constructor
(`0xA0/0xA1/0xA3/0xB0/0xB1/0xB3/0x98`) guards only the declared length bound, not
`byte_size(rest) >= n`; `<<b::binary-size(^n), _>> = rest` raises MatchError on a
truncated frame body. Witnessed probe:

```
frame body = <<0x00,0x53,0x10, 0xA1, 200, 1, 2, 3>>   # declares 200-byte string, 3 bytes follow
=> RAISED: %MatchError{term: <<1, 2, 3>>}
```

The crash-only law is honored (connection dies), but untyped — the claim "never raises"
in the moduledoc is unreceipted/false, and the typed-exit discipline (BK-116 R-116-1
class) is broken at the decoder layer while amqp10_session/link exits ARE typed tuples
(contrast `exit({:unknown_link_handle, handle})`). Also observed in read: the
0xC0/0xD0 list/map constructors ignore their declared `_size` field entirely
(elements' consumed bytes are never checked against it; trailing bytes inside a
declared list size are silently absorbed).

**Ticket WIRE-EXP4-2 (repair):** add byte-available guards to the sized element clauses
(or rescue-to-typed at the decode_frame boundary), either tighten or receipt the
"never raises" doc claim, and cross-check 0xC0/0xD0 declared size vs consumed bytes.
Falsifier: truncated 0xA1 string must return `{:error, :truncated_element}`, never
raise.

### F3 — Kafka Records best-effort tail drop + recordsCount never cross-checked (WITNESSED)

`lib/smalt/messaging/kafka/records.ex` `parse_records/1` is documented best-effort at
the tail: parsing stops at the first malformed record and returns everything before it
with `{:ok, ...}` — never a typed error, and `count/1` (the header recordsCount) is
never cross-checked against the parsed list anywhere. Witnessed probe:

```
CRC-valid batch, recordsCount=2, 1 valid record + malformed tail:
=> verify_batch: :ok; count: {:ok, 2}; parse_records: {:ok, [1 record]}
```

Consequences: `Log.admit_one/3` stores header `count` (2) while the records actually
parsed/fanned out is 1 — `fan_out_eh/3` uses the parsed list, so the EH consumer leg
can silently receive fewer records than the header (and the stored count) claim. The
watermark advances by the unverified header count, so offsets reference records that
were never fan-out-delivered to the EH leg. Never a kill, never a warning (the
`{:error, _}` warning in `fan_out_eh` is unreachable for this class — parse_records
only errors on byte_size < 61; the tail-drop path returns {:ok, short_list}).

**Ticket KAFKA-EXP4-3 (repair):** cross-check `Records.count/1` == length(parsed) in
`Log.admit_one` (or make parse_records return `{:error, :truncated_records}` on tail
malformity and let produce_partition kill per the crash-only law); same check in
fan_out_eh before fan-out. Falsifier: CRC-valid batch with malformed tail must not
store with count 2 / fan out 1.

### F4 — Kafka reads on unknown topic/partition answer success (code-cited)

`lib/smalt/messaging/kafka/log.ex` `high_watermark/2` returns 0 and `fetch/3` returns
`[]` for ANY {topic, partition} — so ListOffsets v0/v1 and Fetch v0 on a nonexistent
topic/partition return an empty SUCCESS response with error 0 instead of error 3.
`Wire.error_code(:unknown_topic_or_partition)` (kafka/wire.ex line 73) is defined but
never emitted on the read path. Additionally, Produce accepts ANY partition index >= 0
and auto-creates the partition (Log.produce accepts p >= 0 unbounded; Metadata
advertises `partition_count()` partitions but produce/fetch serve any index) — the
partition-index bound is unenforced. Code-cited, not probed end-to-end.

**Ticket KAFKA-EXP4-4 (repair):** emit error 3 on reads of unknown {topic, partition}
where the partition index is outside the topic's served partition range (or
auto-create consistently and register the divergence as a KD row); bound the partition
index in Log.produce/fetch by the configured partition_count.

### F5 — Web PubSub router: unauthenticated token mint + server push (code-cited, divergence-class)

`lib/smalt/webpubsub/router.ex`: `POST .../generateToken` and `.../negotiate` accept no
credential at all and `roles_from_conn/1` DEFAULTS to both all-groups wildcards
(`["webpubsub.joinLeaveGroup", "webpubsub.sendToGroup"]`) when no role param is given;
`POST .../groups/:group/send` has no auth at all. The real service gates these
server-API faces behind the server API key/AAD. On a loopback emulator this is arguably
a KD-row divergence, not a defect: real-shape clients do carry the key. Code-cited,
not probed.

**Ticket WPS-EXP4-5 (repair or KD row):** either gate generateToken/negotiate/push on a
server credential (real parity) or mint a KD row registering the open-face divergence
with a close condition. Do not silently leave it neither-registered-nor-gated.

### F6 — Socket dispatch: untyped crash on missing keys + leaveGroup permission asymmetry (code-cited)

`lib/smalt/webpubsub/socket.ex` `dispatch/3` has no fallthrough clause:
`joinGroup`/`sendToGroup`/`event` with a missing `"group"`/`"data"`/`"event"` key falls
through all clauses → FunctionClauseError → connection killed with no error frame.
Crash-only-ish, but untyped — the client gets a dead socket, not the protocol's error
frame. Separately, `leaveGroup` has NO permission check (joinGroup requires
`webpubsub.joinLeaveGroup` role, leave does not) — defensible per real-service
semantics (leave is free), but it is an unregistered asymmetry.

**Ticket WPS-EXP4-6 (repair):** add a catch-all `dispatch(_, _, state)` clause
answering the protocol error frame; register (or check) the leave-asymmetry explicitly
in the AZ-5 receipt.

## Premise rot / unreceipted claims

- **Unreceipted claim, F2**: "decode never raises on remote input"
  (`frame_decoder.ex` moduledoc) — false as written (witnessed MatchError). Doc
  tightening rides ticket WIRE-EXP4-2.
- **Unreceipted claim, F3**: `fan_out_eh`'s `{:error,_}` warning is unreachable for the
  tail-drop class — the silent drop has no observation point at all.
- **Premise rot: none new** in the four front-ends beyond the excluded set.
- **Environment note (not a finding)**: the shared checkout's compile was transiently
  frozen mid-sweep by another lane's in-flight `lib/smalt/egress_router.ex` edit
  (mismatched-delimiter compile error, dirty at 2026-10-22 ~00:19). Compile-freeze SLA
  (10-min fix-or-revert) applies to that lane, not this one; probes were run by
  compiling the target modules standalone (scratch beams in /tmp, `_build/dev`
  untouched, no tree writes besides this receipt).

## Verification receipts

- FrameDecoder MatchError: beam-loaded probe against
  `_build/dev/lib/smalt/ebin/Elixir.Smalt.Amqp10.FrameDecoder.beam`, output
  `RAISED: %MatchError{term: <<1, 2, 3>>}`.
- Token absent-claims admission: standalone-compiled `Smalt.WebPubSub.Token` (elixirc,
  joken on -pa) probe, output
  `ADMITTED: uid="" roles=["webpubsub.sendToGroup"]` for a no-aud/no-exp/no-nbf/no-sub
  JWT.
- Records tail-drop: standalone-compiled Wire+Records probe, output
  `verify: :ok  count: {:ok, 2}` / `parse_records: {:ok, [1 record]}` with
  recordsCount=2.
- Probe-method note for the repair lane: an earlier probe returned
  `parse_records -> {:ok, []}` — that was a mis-encoded probe record (unsigned varint
  6 where the signed-zigzag encoding 12 was required), NOT a multi-record parse bug;
  the corrected probe shows multi-record batches parse fully. Recorded so
  KAFKA-EXP4-3 does not chase the false lead.
