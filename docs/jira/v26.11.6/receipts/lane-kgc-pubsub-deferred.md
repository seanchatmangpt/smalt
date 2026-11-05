# K-GC — Pub/Sub gRPC face, deferred by operator architecture ruling (v26.11.6+)

Standing: PARTIAL_ALIVE

Face deferred per operator ruling (this session): the GCP face already
exists in arcus as a REST-shaped json-envelope server — arcus
`internal/ingress/gcp/server.go` (235 lines, tests green, adapter opTable
rows `gcp-pubsub.*` with transcoders wired). The F-P2 transport bet
(grpc-status in initial HEADERS over Bandit h2c) is therefore moot for the
target architecture, and independently the F-P2 probe WITNESSED the gate
closed on the Bandit-Plug shape: grpcio 1.85.1 rejects both
grpc-status-in-initial-HEADERS+DATA and DATA+END_STREAM with no trailers
(`Stream removed (Data frame with END_STREAM flag received)`), and Bandit
Plug (pinned 1.14.1) has no response-trailer emission, so no Bandit-Plug
shape serves real grpcio DATA-bearing unary calls.

## Landed surface (court-verified this session)

`lib/smalt/data_plane/pubsub_grpc/wire.ex` — pure protobuf wire codec for
the pubsub.proto subset (field numbers pinned: PubsubMessage data=1 /
attributes=2 map / message_id=3 / publish_time=4 Timestamp / ordering_key=5;
Publish, Pull, Acknowledge, ModifyAckDeadline envelopes; PublishResponse
message_ids unpacked; unknown-field skip by wire type; truncated or
overlong varint → typed `{:error, :bad_varint}`).

`test/smalt/data_plane/pubsub_grpc/wire_test.exs` — 13/13 PASS this
session (`mix test test/smalt/data_plane/pubsub_grpc/wire_test.exs`): varint
roundtrips incl. (1<<<63)-1, known-byte pins (300 → AC 02), truncated
varint typed refusal, unknown-field skip by all four wire types,
PubsubMessage full-field roundtrip, map-entry decode, Publish/Pull/Ack/
ModifyAckDeadline envelopes, pull-response ack_id/message parity.

## Deferred surface (compiles; NOT court-verified)

`plug.ex` + `pubsub_grpc.ex` facade + `engine.ex` under
`lib/smalt/data_plane/pubsub_grpc/` — the deferred face. Engine courts
16/17 this session (`engine_test.exs`): registry CRUD typed refusals,
unique server message_ids, pull/ack/redelivery pass; the open item is the
F-P3 durable-cursor fold after Engine restart (tail folds 0 instead of 1;
CursorPersist folds sealed matter-"aoq" segments only — the seal-on-
terminate path needs re-derivation if the face revives). These files are
deferred-face capital to re-derive at revival; the wire.ex codec is
transport-agnostic capital. No coordinator wiring was made
(application.ex untouched — disclosed wiring line lives in the facade
moduledoc).

Scratch artifacts (`/tmp/kgc_*`, `/tmp/fp2_gate_probe.py`, probe venv) are
/tmp scratch, not landed. KD rows for this surface are superseded by
arcus-side divergence tracking.
