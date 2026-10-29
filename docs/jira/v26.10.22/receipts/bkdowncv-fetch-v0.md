# BK-DOWNCV — KD-181 closed: Fetch v0/v1 down-converts stored magic-2 to legacy message-set v0

Standing: ALIVE. Context: solo.

## Scope (lease)

Lane BK-DOWNCV owned `lib/smalt/messaging/kafka/conn.ex` (fetch response
path) + a new court `test/internal/kafka_downcv_court_test.exs` + probe
`tmp/bkdowncv_probe.py` + witness harness `tmp/bkdowncv_witness.exs` (tmp =
scratch, unindexed) + the KD-181 register row (flip only). No other `lib/`
or `test/` files touched.

## The divergence (KD-181 row, KNOWN_DIVERGENCES.md)

Fetch responses v0/v1 carry message-set v0/1, so real Kafka down-converts
stored magic-2 RecordBatches to legacy frames on low-version fetches;
smalt served the stored magic-2 bytes verbatim — a real legacy client
(api_version=(0,9)) received the batch bytes as ONE garbage legacy record
(value = the raw batch bytes, timestamp None). Registered fresh by lane
KD-FV0 (receipt `docs/jira/v26.10.22/receipts/kdfv0-row.md`).

## Implementation (`lib/smalt/messaging/kafka/conn.ex`)

`take_batches/2` → `take_batches/3` (fetch api_version threaded in).
`serve_batch/3` dispatches on BOTH the magic byte and the fetch version:

- Fetch v0/v1 + stored magic-2 batch → `down_convert/2`: parse the records
  with the SAME parser the produce face verifies
  (`Records.parse_records/1` — the KD-180/F3 count cross-check fires here
  too; a mismatch throws typed `{:down_convert_failed, reason}`, caught in
  `route_fetch` and converted to the crash-only kill — a produce-verified
  batch never fails here, so that arm is a crash-only face, never a
  best-effort skip). Each record re-encodes as a legacy message-set v0
  frame: `crc u32 | magic 0 | attrs 0 | keyLen i32 | key | valueLen i32 |
  value`, IEEE CRC32 over post-CRC bytes (the same face
  `Records.verify_batch/1` checks), wrapped `{offset i64, size i32}` with
  the offset stamped per record = base + index (offset_delta is the record
  index in a well-formed batch; the legacy wrapper is the only offset face
  on this format — the broker base lives in the stored batch's baseOffset
  field AND lands in each wrapper offset: dual stamp per the BK-KFKV-1
  law).
- Fetch v2 → byte-exact verbatim serve (unchanged law, now named).
- Legacy stored frames → verbatim (unchanged).

`# KD-COVERS: KD-181` token on `serve_batch/3`.

## Courts (fresh runs, actual exits, this session)

`test/internal/kafka_downcv_court_test.exs` (4 legs):

- F3 no-regression: Fetch v2 of a magic-2-stored partition serves the
  stored batch verbatim under {base, size} — `[{^base, ^batch}]` from the
  real-wire message set.
- F2 wire face: Fetch v0 of a magic-2-stored partition down-converts — the
  record arrives as a legacy v0 frame (magic 0, IEEE CRC32 valid through
  `Records.verify_batch/1`, key+value byte-exact), and the raw magic-2
  bytes appear NOWHERE in the v0 message set.
- F4 count laws: legacy frame counts 1 (KD-180 law, hwm +1); magic-2
  2-record batch counts 2, hwm +2.
- F1 falsifier: real kafka-python-ng 2.2.3 client, api_version=(0,9) →
  Fetch v0, consuming a partition holding a real magic-2 batch + 2
  client-produced legacy records — the KD-FV0 witness shape.

Trio fresh green (downcv + exp4 + wire, two different seeds):

```
$ MIX_BUILD_ROOT=_build-bkdowncv MIX_ENV=test mix test test/internal/kafka_downcv_court_test.exs test/internal/kafka_exp4_court_test.exs test/internal/kafka_wire_test.exs
Result: 23 passed
$ … same trio --seed 987654
Result: 23 passed
```

Standalone falsifier witness (fresh boot, ephemeral port 53739, magic-2
stored via the in-matrix Log.produce path, real client Fetch v0):

```
$ MIX_BUILD_ROOT=_build-bkdowncv MIX_ENV=test mix run --no-start tmp/bkdowncv_witness.exs
KAFKA_PORT=53739
MAGIC2_STORED part=0 value=DNCVW418EA263-m2-FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
LEGACY_PRODUCED 2
REC b'DNCVW418EA263-m2-FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF' ts None off 0
REC b'DNCVW418EA263-lg0' ts 1792689401680 off 1
REC b'DNCVW418EA263-lg1' ts 1792689401681 off 2
GOT 3 prefix records
PASS down-convert byte-exact n=3
--- probe exit 0 ---
exit=0
```

The pre-fix KD-FV0 witness delivered the batch bytes as ONE garbage legacy
record (value = raw batch bytes). Post-fix the same shape delivers the
magic-2 record as its own frame, value byte-exact, ts None, offset 0 — the
close condition holds byte-exact.

## Cross-lane finding (disclosed, not landed here)

First trio run (shared seed shuffle) witnessed the BK-KFKC real-client leg
(exp4, NOT lane-owned) failing with struct.error in legacy_records.py —
root cause: my first court draft stored magic-2 batches on partition 1,
and BK-KFKC's auto-detect consumer (Fetch v2, legacy parser) met verbatim
magic-2 bytes — the KD-181 divergence face itself, triggered by partition
pollution. Fix: the downcv court keeps ALL its legs on partition 0 (the
magic-2 face of the exp4 F3 legs); partition 1 stays legacy-only for
BK-KFKC. Documented in the court file header. After the move: trio green
twice, exp4 alone 10/10.

Pre-existing residue (not session-introduced): KD-168 registrar hold
(FLIP-PENDING-WITNESS, witnessed before this lane opened).

## Standing

ALIVE — close condition executed on the real wire + a real legacy client;
KD-181 flip applied receipt-gated (`scripts/kd_flip.py --apply --only
KD-181 --witness KD-181=<this receipt>`).
