# K-IN — Kinesis REST face (lane K-IN, v26.11.6+)

Standing: ALIVE — both courts executed green this session against the exact
landing subject: Elixir integration court 8/8
(`test/integration/kinesis_rest_roundtrip_test.exs`), real-boto3 court 3/3
(`verification/py/test_wf10_kinesis.py`) over real TCP with the real route
module and the real AWS SDK. No `Process.sleep` in the lane's lib or court
files. Scratch artifacts (`tmp/kin_py_harness.exs`, harness BEAM) deleted /
confirmed down.

**Disposition (operator ruling, 2026-11-04):** the Kinesis face stays as
the BEAM emulator-parity twin (EH-REST precedent); the STRATEGIC AWS face
is arcus ingress/aws (server.go + sigv4) — the membrane owns external
protocol interception, smalt stays standards-native. No rework; mounted
router line stays.

## Subject (files owned and landed by this lane)

- `lib/smalt/egress/KinesisRoutes.ex` (NEW) — AWS Kinesis JSON protocol face
  (POST /, X-Amz-Target `Kinesis_20131202.*`) over the SAME EventHubs
  partition store (hub = stream). 7 actions dispatched: PutRecord,
  PutRecords, GetShardIterator, GetRecords, ListShards, DescribeStream,
  ListStreams; unknown target → 400 `InvalidActionException`.
- `mix.exs` — additive `{:aws_signature, "~> 0.4"}` (0.4.3 already in
  mix.lock via explorer; pin is additive identity only).
- `verification/py/pyproject.toml` — additive boto3/botocore in the dev
  extra.
- `verification/py/test_wf10_kinesis.py` (NEW) — real-boto3 court; wf9 was
  taken by the HC kafka lane mid-wave (first-minted-wins;
  `test_wf9_kafka.py` verified on disk).
- `test/integration/kinesis_rest_roundtrip_test.exs` (NEW) — clones the EH
  template (halt_if_sent guard, typed error tuples, capped read_body,
  test-local `W6rKinesisFallthrough` mount, raw `:httpc`).

## Verification ladder (commands + exits, this session)

1. `MIX_BUILD_ROOT=_build-laneKIN asdf exec mix compile` — exit 0. Only
   pre-existing warnings from other lanes' in-flight files; my file
   compiles clean.
2. `MIX_BUILD_ROOT=_build-laneKIN asdf exec mix test test/integration/kinesis_rest_roundtrip_test.exs`
   — exit 0, **8 passed**, 0 failures (final run after the shard-idx fix).
3. boto3 court against a scratch BEAM harness booting the REAL route chain
   (`tmp/kin_py_harness.exs`, since deleted): 3 passed, 0 failures.
4. Scratch BEAM killed: `pkill -f kin_py_harness`; harness log tail shows
   clean boot/shutdown.

## Route contract highlights

- SigV4 dual posture (KD-KIN-1): pinned `config :smalt, :kinesis` → real
  re-sign-and-compare via `:aws_signature`; unpinned dev admits any
  non-blank AWS4-HMAC-SHA256 header; missing → 403
  `UnrecognizedClientException`.
- KD-76 shard law mirrored verbatim (md5(pk) first byte rem 2), 2-shard
  registry `shardId-000000000000/001`; store partition =
  `{stream}/partitions/{0|1}` — the same row the EH face writes.
- SequenceNumber plain decimal (KD-KIN-2).
- Iterator token `Base.url_encode64("stream|shard|after_seq")`, W-close by
  construction; AT inclusive vs AFTER exclusive court-pinned.
- Errors `{"__type": "com.amazonaws.kinesis#<Code>", "message"}`;
  ResourceNotFound at 400 (botocore metadata law).

## KD rows

KD-KIN-1..4 minted in the wave register
`docs/jira/v26.11.6/KNOWN_DIVERGENCES.md` (the register file itself was
created by another lane mid-wave; I appended the KD-KIN rows; first-minted
wins, the register is authoritative over this receipt).

## Lessons (witnessed this session, disclosed for future lanes)

1. `aws_signature` is sign-only — verification = re-sign-and-compare. The
   re-sign must (a) filter to request-PRESENT signed headers (the lib
   re-injects `x-amz-content-sha256` and its own date header into the
   canonical set), and (b) DEDUPE the SignedHeaders names — the lib's own
   output SignedHeaders string can carry duplicate entries (witnessed
   `x-amz-date;x-amz-date`), and duplicated canonical headers re-sign to a
   different signature than the client's single entry.
2. `:aws_signature.sign_v4` requires binary Method, full URL with host for
   `parse_url` (a bare `"/"` fails the `#{host := _, path := _}` match), and
   mixed binary/charlist string args function_clause — use all-binaries for
   akid/secret/region/service, binary method, and a full URL string.
3. The EventHubs partitions table carries `{:seq_counter, path}` tuple keys
   alongside binary partition keys — any tab2list scan must filter on
   binary keys (witnessed: ListStreams 500 FunctionClauseError in
   String.split on the tuple key after a first publish).
4. Concurrent-lane drift: `flatbuf.ex` compile freeze lifted after ~7 min
   of bounded polling; another lane created the v26.11.6 KD register and
   test_wf9_kafka.py mid-lane — both collisions resolved first-minted-wins.

## Coordinator mount (LANDED this session — confirmed on disk)

The disclosed one-liner landed as the coordinator's runtime-atom idiom in
`lib/smalt/egress_router.ex` (`:kinesis_rest_face` delegator at line 181,
`defp kinesis_rest_face` at 214 — after `:apim_gateway_plane`, before
`:w6r_fallthrough`, same sent/halted end-of-chain law, parse-checked). The
lane-outstanding item is CLOSED; the boto3 court's `_face_mounted`
detection now serves as the mounted-face probe against any substrate boot
with this tree.
