# Receipt: BK-KFKC2 — adversarial re-verify of the BK-KFKC legacy-count repair

- **Lane**: BK-KFKC2 (`/Users/sac/smalt`, canonical checkout, `_build-kfkc2`)
- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Mode**: read-only verify lane; only this receipt written (probe scripts in `tmp/`, scratch)
- **Verify subject**: BK-KFKC receipt `bkkfkc-legacy-count.md` (landed 07:03,
  ALIVE), which repairs the BK-KFKSKEP-witnessed legacy-face count defect
  (`bkkfkskep-kafka-audit.md`, read first).

## Verdict

Every BK-KFKC claim re-verified on the CURRENT tree (post-landing, including
the post-receipt `# KD-COVERS: KD-180` comment edit to
`lib/smalt/messaging/kafka/records.ex` — behaviorally identical, re-suites
run after it) with fresh runs on fresh ephemeral nodes: 19/19 suite tests,
all adversarial raw-wire legs, real kafka-python-ng legs, and a live
seal→restart→replay cycle. **All five mandated legs hold; no open findings.**

## Leg 1 — exact witnessed 60-byte legacy produce → watermark +1 (fresh)

Fresh node, fresh journal, single kafka-python-ng produce of the exact
60-byte value `0123456789`×6 (the audit's defect class):

```
$ python3 scripts/az1/kafka_probe.py --port $KP --mode produce \
    --values "012345678901234567890123456789012345678901234567890123456789"
PRODUCED ["012345678901234567890123456789012345678901234567890123456789"]   exit 0
$ fetch_raw("kafka", 0, 0) / ("kafka", 1, 0)
HWM p0=0 p1=1            # pre-fix this was 1,116,385,94x (0x42424242)
K1 PASS: hwm advanced by exactly 1
```

Also witnessed earlier same-session on a different fresh boot: `HWM p0=1
p1=0` — partition choice varies by client stickiness, +1 either way.

## Leg 2 — legacy frame with lying bytes 57..60 refuses the lie, advances exactly 1

CRC-valid legacy magic-0 frame, 91 bytes, with `0x42424242` planted at frame
bytes 57..60 (value bytes 43..46, planted BEFORE CRC computation — my first
attempt planted it after CRC and was correctly CRC-killed, which is itself
a fresh witness of the crash-only law):

```
$ python3 tmp/bkkfkc2_probe.py $KP k2
PASS K2 legacy lying-bytes frame admitted typed :: err=0 hwm 4->5 (delta=1, want 1)
   (final tip-tree cycle: both K2 lines PASS — value byte-exact exact=True)
PASS K2 lying-frame value byte-exact on fetch :: err=0 exact=True
SUMMARY: OK                                               exit 0
```

The lie is never read: legacy count is lawfully 1 (magic-dispatched
`count/1`), hwm advances by exactly 1, value fetches back byte-exact. This
leg doubles as the dedicated legacy byte-exactness witness on the raw-wire
face (single-frame sequence, fetch-back `exact=True`).

## Leg 3 — magic-2 face unchanged (all BK-KFKSKEP adversarial legs re-run)

```
$ python3 tmp/bkkfkskep_wireprobe.py $KP    (fresh journal boot)
PASS A magic-2 produce answered (not killed) :: err=0 base_offset=0
PASS A magic-2 fetch-back byte-exact (batch verbatim, offset stamped) :: exact=True len=100/100
PASS B legacy magic-0 produce admitted :: err=0 base=1
PASS C Metadata v0+v1 / ListOffsets v0+v1 / Fetch v0+v1+v2 / Produce v0 in-session
PASS C out-of-matrix key=0 v3 / 1 v3 / 2 v2 / 3 v2 -> conn killed
FAIL C out-of-matrix key=18 v1 crash-only :: answered: 002300000000     (ADJUDICATED, below)
PASS D pipelined corr echo in order :: got=[101, 102, 103]
PASS E oversized 2MiB produce answered typed :: err=0 base=3
```

- **key=18 v1 adjudicated**: err 0x23 = 35 UNSUPPORTED_VERSION — the
  KIP-183 downgrade face, the ONE documented exception to crash-only
  (`lib/smalt/messaging/kafka/conn.ex:133-142`: "unsupported ApiVersions is
  the one exception to the crash-only law"; kafka-python version negotiation
  depends on it). Same adjudication as the audit receipt. Not a finding.
- **leg B `exact=False` adjudicated as probe artifact**: the leg fetches
  offset 0 after leg A already filled it — on the non-empty journal the
  fetch-back compares the wrong batch. The dedicated single-frame legacy
  byte-exactness witness is leg 2 above (`exact=True`) plus the suite's
  seal+replay witness. Re-ran this adjudication twice (dirty and fresh
  journals, identical shape both times — offset-0 collision in both).
- **new adversarial leg K2b (this lane)**: hand-rolled magic-2 batch with
  CRC-valid lying `recordsCount=5` (one real record):

```
PASS K2b magic-2 lying recordsCount: hwm unchanged :: hwm 6->6 (lie would be +5)
PASS K2b magic-2 lying recordsCount: typed face :: answered err=2 base=-1   exit 0
```

  F3 law holds through the wire face: typed CORRUPT_RECORD, hwm untouched.

## Leg 4 — real client produce+consume byte-exact + negative probe (fresh journal)

```
$ python3 scripts/az1/kafka_probe.py --port $KP --mode produce --values "kfk1-abc,...,kfk5-mno"
PRODUCED ["kfk1-abc", "kfk2-def", "kfk3-ghi", "kfk4-jkl", "kfk5-mno"]      exit 0
$ python3 scripts/az1/kafka_probe.py --port $KP --mode consume --values "<the same 6>"
PASS consume byte-exact n=6                                                exit 0
$ python3 scripts/az1/kafka_negative_probe.py $KP
PASS bad-CRC conn killed
PASS produce-v9 conn killed
SUMMARY: 2/2 PASS                                                          exit 0
```

## Leg 5 — journal replay byte-exact on the legacy face (live seal→restart)

Graceful seal via `JournalSink.seal(Smalt.Messaging.Kafka.Sink)` (SIGTERM
does NOT seal — witnessed: a SIGTERM-stopped node replayed hwm=0/empty; the
seal→exit→restart cycle replays full state):

```
boot F (port 50518): K1+5values+K2+K2b landed; snapshot hwm=6, mset 313 bytes
touch ctrlA.seal -> SEALED frames=N ; ctrlA.exit -> BYE
boot G (port 49535): same SMALT_KAFKA_LOG_DIR
K5 PASS: err=0 hwm 6->6 mset_len 313==313 exact=True
```

313-byte partition-0 message set (kfk3/kfk4 legacy frames + the K2
0x42424242-lying frame) replayed hex-identical, hwm preserved. The
kafka_wire_test seal+replay byte-exact witness also passed in-suite.

## Suites (fresh, tip tree, post-KD-COVERS edit)

```
$ MIX_BUILD_ROOT=_build-kfkc2 mix test test/internal/kafka_exp4_court_test.exs \
    test/internal/kafka_wire_test.exs
Finished in 64.1 seconds ... Result: 19 passed                            exit 0
```

(9 exp4 incl. both BK-KFKC falsifier tests — "60-byte-value legacy frame
counts 1, hwm advances by 1 (not 0x42424242)" and magic-1 parse; 10 wire
incl. sieve produce/consume, seal+replay byte-exact, crash-only, F3/F4 and
their non-vacuity faces.)

## Typed residue (no open defects)

- Earlier mid-flight suite run (during BK-KFKC's in-flight edits, before
  landing) failed 4/18 — that was the moving tree, not the landed repair;
  the landed tree is 19/19.
- Wireprobe leg B fetch-offset-0 artifact and the key=18 KIP-183 face are
  probe/adjudication notes above, not defects.
- One SIGTERM-does-not-seal observation is a scratch-harness lesson (my
  probe stopped nodes with kill; data loss was my harness, not the
  product — sealed replay is the supported restart path and is byte-exact).

## Falsifiers

- Leg 1 falsifier ("hwm jumps to 0x42424242 class") — REFUTED on the landed
  tree: +1 exactly, twice on two fresh boots.
- K2b falsifier ("lying recordsCount advances hwm") — REFUTED: typed err=2,
  hwm unchanged.
- Crash-only falsifiers (bad CRC, produce v9, out-of-matrix versions) — all
  hold; key=18 v1 is the documented KIP-183 exception.
- K5 falsifier ("replay corrupts legacy face") — REFUTED: byte-exact, hwm
  preserved.
