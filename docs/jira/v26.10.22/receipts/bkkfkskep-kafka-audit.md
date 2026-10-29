# Receipt: BK-KFKSKEP — kafka wire-face skeptic audit

- **Lane**: BK-KFKSKEP (`/Users/sac/smalt`, canonical checkout)
- **Standing**: PARTIAL_ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Mode**: read-only skeptic audit; only this receipt written (probe scripts in `tmp/`, scratch)

## Verdict

All seven BK-122r repairs, KAFKA-EXP4 F3/F4, and the KD-174 legacy message-set
face **re-verified on the current tree with fresh runs** — 15/15 suite tests,
real-client probes byte-exact, crash-only law held on every leg. The audit
additionally **found one new open defect on the legacy (magic-0/1) face**:

> **NEW DEFECT (KD row owed, candidate KD-176)** — `Records.count/1` clause
> ordering (`lib/smalt/messaging/kafka/records.ex:104-111`): the first clause
> `count(<<_::binary-size(57), n::unsigned-integer-size(32), _::binary>>) when n > 0`
> matches ANY binary ≥ 61 bytes — including legacy magic-0/1 frames ≥ 61 bytes
> — and reads bytes 57..60 (payload bytes) as the magic-2 `recordsCount`.
> The legacy clause (`{:ok, 1}`) is unreachable for frames ≥ 61 bytes. A legacy
> frame ≥ 61 bytes (value ≥ 47 bytes) therefore gets `count` = payload bytes,
> `Log.admit_one` stores it and advances the watermark by that garbage:
> **a single 60-byte real-client produce jumped the partition watermark from
> 0 to 1,111,638,594 (= 0x42424242, the `BBBB` bytes at 57..60)**. It also
> bypasses the F3 cross-check law on the legacy face: `admit_one` never
> compares the legacy count against the parsed record list.

## Verification ladder (fresh runs, actual exits)

### 1. Real-client probes re-run fresh (port re-booted per run)

```
$ python3 scripts/az1/kafka_probe.py --port <p> --mode produce --values "kfk1-abc,...,kfk5-mno"
PRODUCED ["kfk1-abc", "kfk2-def", "kfk3-ghi", "kfk4-jkl", "kfk5-mno"]    exit 0
$ ... --mode consume ... → PASS consume byte-exact n=5                    exit 0
$ python3 scripts/az1/kafka_negative_probe.py <p>
PASS bad-CRC conn killed
PASS produce-v9 conn killed
SUMMARY: 2/2 PASS                                                         exit 0
```

### 2. Suites (fresh build root `_build-kfkskep`)

```
$ MIX_BUILD_ROOT=_build-kfkskep mix test test/internal/kafka_exp4_court_test.exs \
    test/internal/kafka_wire_test.exs
Finished in 43.6 seconds (0.00s async, 43.6s sync)
Result: 15 passed                                                        exit 0
```

(6 exp4 = F3 falsifier + F3 non-vacuity ×2 + F4 wire error-3 + F4 unit + F4
produce-bounds; 9 wire = produce/consume sieve, seal+replay byte-exact — the
legacy magic-0/1 journal-replay byte-exact witness — crash-only, F3, F4, F4
non-vacuity.)

### 3. BK-KFKSKEP adversarial raw-wire probe (`tmp/bkkfkskep_wireprobe.py`, 18 legs)

```
PASS A magic-2 produce (valid CRC32C batch, Produce v2): err=0, base stamped,
     batch bytes re-served verbatim on fetch (modulo broker offset stamping)
PASS B legacy magic-0 produce admitted + frame re-served byte-exact
PASS C Metadata v0+v1 in one session; ListOffsets v0+v1; Fetch v0+v1+v2;
     Produce v0 in the same session (served extremes mixed freely)
PASS C out-of-matrix Produce v3 / Fetch v3 / ListOffsets v2 / Metadata v2 ->
     CRASH-ONLY kill (server log: {:unsupported_version, key, ver})
PASS C ApiVersions v1 -> error 35 UNSUPPORTED_VERSION (KIP-183 downgrade
     face — intentional, documented in conn.ex, NOT a crash-only violation)
PASS D pipelined requests: corr 101/102/103 echoed in order
PASS E oversized 2 MiB produce: answered typed err=0; fetch still sane
```

## The defect, precisely

Fresh node, empty journal, single real-client produces on partition 0:

```
produce "small-1" (33-byte legacy frame < 61)  → hwm("kafka",0) = 0  (part 1)
produce 60-byte value via kafka-python-ng      → hwm("kafka",0) = 1111638594
                                        1111638594 == 0x42424242 ("BBBB")
```

The 60-byte value lands at base 0; `count` stored = bytes 57..60 of the frame
= `0x42424242`; `smalt_kafka_next` advances by that. Mechanism: `admit_one`
calls `Records.count(raw)` BEFORE dispatching on magic — clause 1 wins for
legacy frames ≥ 61 bytes. `parse_records` legacy clause still parses exactly
1 record, so the F3 cross-check never fires. Delivery itself is unaffected
(value consumed back byte-exact), but offsets/hwm are garbage from the first
≥ 47-byte value onward, and journal replay restores the corrupted counts.

Fix direction (owner lane): dispatch `count/1` on magic first (legacy clause
before the bytes-57..60 clause), and either cross-check legacy count == 1
against `parse_records` or route legacy count through the parse — restoring
the F3 law on the legacy face.

## Falsifiers

- F3 (recordsCount mismatch typed, hwm unchanged) — holds on the magic-2
  face (suite + probe), **fails on the legacy face for frames ≥ 61 bytes**
  (the new defect above).
- F4 (unknown {topic, partition} → error 3) — holds (suite).
- Crash-only (bad CRC / Produce v9 / out-of-matrix versions kill) — holds.
- KD-174 falsifier — the legacy face is served; real clients produce through
  it; but the hwm-corruption class above is a live divergence on that face.

## Standing

PARTIAL_ALIVE: every claimed repair verified fresh; one new open defect class
found and receipted (legacy-face count clause). KD row + repair owed by the
kafka owner lane; `kd_flip` flips are receipt-gated and not taken here.
