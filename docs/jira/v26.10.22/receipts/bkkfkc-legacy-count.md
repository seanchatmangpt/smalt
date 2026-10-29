# Receipt: BK-KFKC — legacy-face count/1 defect repair (BK-KFKSKEP follow-up)

- **Lane**: BK-KFKC (`/Users/sac/smalt`, canonical checkout, `_build-bkfkfc`)
- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Owns**: `lib/smalt/messaging/kafka/records.ex` (+ `log.ex` count path —
  NOT touched: `admit_one` needed no change; dispatching `count/1` on magic
  first restores the F3 law through the existing with-chain), the kafka_exp4
  court extension, this receipt.

## Defect repaired

BK-KFKSKEP (receipt `bkkfkskep-kafka-audit.md`, read first) witnessed:
`Records.count/1` clause ordering read bytes 57..60 of ANY binary ≥ 61B as
the magic-2 `recordsCount`, so legacy magic-0/1 frames ≥ 61B (value ≥ 47B)
got count = payload bytes — a single 60-byte kafka-python-ng produce jumped
the partition watermark 0 → 1,116,385,94x (0x42424242, the `BBBB` bytes at
57..60), with the EXPL-4 F3 cross-check never firing on the legacy face.

## Fix (`lib/smalt/messaging/kafka/records.ex`)

1. `count/1` now dispatches on the magic byte FIRST: the magic-2 clause
   requires magic == 2 at byte 16 and size ≥ 61 (reads the header field at
   57..60, `{:error, {:bad_count, n}}` on n ≤ 0 — the old negative-count
   fallback face is preserved inside the magic-2 clause); the legacy
   magic-0/1 clause (count = 1) precedes any bytes-57..60 read; everything
   else is typed `{:error, :too_short}`. A legacy frame can no longer have
   its payload bytes misread as a count.
2. F3 cross-check extended to the legacy face: the legacy `parse_records`
   clause now runs the declared count (1, from the magic dispatch) against
   the parsed record list — mismatch answers typed
   `{:error, :record_count_mismatch}`. `log.ex` needed no edit: `admit_one`'s
   with-chain picks the law up through `Records.count/parse_records`.

## Court (`test/internal/kafka_exp4_court_test.exs`, extended)

- **BK-KFKC falsifier**: the exact witnessed shape — legacy magic-0 frame,
  60×"B" value (bytes 57..60 = 0x42424242), ≥ 61B — counts 1, produce
  advances hwm by exactly 1, fetch-back + re-parse byte-exact.
- **BK-KFKC corrupt legacy frame**: valueLen claims 100, frame ends early —
  `verify_batch` :ok (CRC-valid), `parse_records`/`count`/`Log.produce` all
  refuse typed (`:too_short`), hwm unchanged.
- **BK-KFKC legacy magic-1**: counts/parses 1, hwm +1 (null-key face).
- **BK-KFKC real-client probe** (`tmp/bkkfkc_probe.py`, BK-KFKSKEP probe
  style — real kafka-python-ng, KAFKALIB=tmp/kafkalib): 60-byte produce
  (explicit partition 1) → summed hwm(part 0)+hwm(part 1) advances by
  exactly 1 (the defect face); bounded-retry consume (4 tries, no-sleep
  doctrine — bounded poll on the probe's PASS observable) over partition 1
  from beginning, byte-exact n=1. Partition-1 scope is deliberate:
  partition 0 carries the F3 non-vacuity magic-2 batch, which the fetch-v0
  legacy client cannot parse (see typed residue).

### Non-vacuity (shim court, real restore)

With the PRE-FIX `records.ex` (`git show f6ea5e54:...records.ex`) swapped in
and everything else unchanged:

```
exit=2
1) test BK-KFKC falsifier: 60-byte-value legacy frame counts 1, hwm advances by 1 (not 0x42424242)
2) test BK-KFKC real-client probe: 60-byte kafka-python-ng produce advances hwm by 1, consume byte-exact
Result: 8/10 passed
```

Exactly the two BK-KFKC defect legs fail on the defective code and pass on
the fix; the eight pre-existing legs pass on both (magic-2 behavior
unchanged). Fixed file restored byte-exact after the run.

## Order-robustness repairs inside the same court file (disclosed)

While extending the court, two PRE-EXISTING legs were witnessed failing at
TRUE HEAD (pre-fix `records.ex` + pre-extension test, `_build-bkfkfc`, runs
7/9 and 8/9): `F3 non-vacuity` (`rawn == batch` byte-exact with baseOffset
bytes = 0 — true only on a virgin partition 0) and `F3 falsifier`
(`fetch(@topic, 0, hwm_before) == []` — same virgin-partition premise).
ExUnit shuffles test order; with `kafka_wire`'s real-client produce-5
landing before them they flake. Repairs (assertions preserved, made
shuffle-robust):

- falsifier: nothing-NEW-stored form — the full visible fetch set (from 0)
  is compared before/after the refused produce, plus hwm unchanged.
- non-vacuity: the built batch is stamped with the expected base offset in
  bytes 0..7 (outside CRC and batchLength coverage, mirroring
  `Log.stamp_base_offset/2`), so the byte-exact fetch-back holds in any
  order; partition-0 asserts otherwise unchanged.
- the three BK-KFKC Log-touching legs run on the top partition
  (`partition_count() - 1`), never touching partition 0's watermark.

## Cross-lane disclosures (compile-freeze SLA + same-checkout fan-out)

- **BK-B7CR** edited this lane's in-flight probe leg mid-session (unique
  per-run value prefix, replacing the fixed `"KKKK…"` value — retries after
  a timed-out consume were state-dependent). Disclosed here per the
  disclosure law; the prefix is threaded through the bounded-retry helper
  in this lane's final integration.
- Coordinator tick checkpoints snapshotted and landed this lane's in-flight
  `records.ex` (with `# KD-COVERS: KD-180` added comment-only by KD-KLV),
  the court file, and an intermediate version of this receipt; this commit
  is the final-state receipt update only (records.ex and the court file are
  byte-identical to HEAD).

## Typed residue

- **Fetch-v0 face vs magic-2 batches (NEW, order-dependent, NOT this lane's
  surface)**: witnessed during court extension — a stored magic-2 batch
  (the F3 non-vacuity batch, 121B) re-served on the Fetch v0/v1 legacy face
  crashes kafka-python-ng's legacy record parser
  (`legacy_records.py` `struct.error: unpack_from requires a buffer of at
  least 131098 bytes … actual buffer size is 121`). Fetch response v0/v1
  carries message-set v0/v1; real Kafka down-converts magic-2 to legacy on
  low-version fetches — smalt serves the magic-2 bytes verbatim. Surfaces
  whenever a consume probe reads a partition from 0 after the magic-2 batch
  is stored (order-dependent under ExUnit shuffle; the `kafka_wire`
  produce-5/consume leg has the same exposure). Owed by a fetch-face lane
  (`conn.ex` fetch response versioning / down-conversion); not repaired
  here — `conn.ex` is outside this lane's lease.
- **KD register**: KD-180 minted and closed by the KD-KLV lane against this
  fix (canonical row + window row, minted-then-closed
  CLOSED-WITH-EVIDENCE). No KD action taken by this lane.

## Verification ladder (fresh runs, actual exits)

```
$ MIX_BUILD_ROOT=_build-bkfkfc mix test test/internal/kafka_exp4_court_test.exs \
    test/internal/kafka_wire_test.exs
Result: 19 passed                                                     exit 0
```

Three consecutive greens (random ExUnit seeds) at 08:03 PDT under
load avg ~20-25 (10 exp4 = 6 pre-existing F3/F4 legs + 4 BK-KFKC legs incl.
the real-client probe; 9 wire = produce/consume sieve byte-exact, sieve
refusal, crash-only negative probe, seal+replay byte-exact, F3/F4 legs).
Earlier same-session evidence: 4 further combined greens while the court
was mid-extension, exp4-only 10 passed, and the shim-court non-vacuity run
above. Load context: consume probes on this shared machine flaked at load
avg ~100 (BK-QREAD census territory) — quiesce precondition applies, per
the corpus premise law.

## Standing

ALIVE: the exact witnessed 60-byte legacy produce counts 1 and advances hwm
by 1 on the fix (hand-built frame leg + real kafka-python-ng probe leg), a
corrupt legacy frame refuses typed, magic-2 behavior is unchanged (all
eight pre-existing court legs + nine wire legs green), and the defect legs
are proven non-vacuous against the pre-fix code.
