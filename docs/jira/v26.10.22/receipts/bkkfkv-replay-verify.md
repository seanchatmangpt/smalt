# Receipt: BK-KFKV — legacy-count repair verify (replay law + KD-174 two-layer + adversarial)

- **Lane**: BK-KFKV (`/Users/sac/smalt`, canonical checkout)
- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Mode**: read-only verify lane; only this receipt written (probe scripts relocated to `scripts/kafka_replay/`, tracked — BK-KLVD)

## Verdict

All four assigned legs hold on the current tree (which carries the BK-KFKC
legacy-count repair in `lib/smalt/messaging/kafka/records.ex` — BK-KFKC's own
receipt `bkkfkc-legacy-count.md` was still pending when this receipt was
written; this verify stands on the tree, not on that receipt):

1. **Journal-replay law (legacy face, post-fix)** — mixed-size legacy series
   (33B / 81B / 120B frames; values 12B / 60B / 99B, two frames ≥ 61B — the
   exact pre-fix corruption shape), fresh empty partition:
   - R1 pre-restart: all three admitted err=0, bases 0/1/2, hwm 0→3 (one per
     frame, never payload-bytes garbage), fetch-back = offset-stamped
     wrappers concatenated to the sent series (254B, byte-exact).
   - Sealed via `JournalSink.seal(Smalt.Messaging.Kafka.Sink)` (trigger-file
     boot-script arm; seal result `%{"bytes" => 389, "frames" => 3, ...,
     "sha256" => "28de1c30...558a64578b7"}`), node killed.
   - R2 post-restart (TTV-4 boot-replay path): boot log
     `[kafka] replayed 3 batch(es) from sealed journal under
     tmp/bkkfkv-kafka-journal`, hwm 3 preserved, 254B byte-exact.
     Counts, offsets, and bytes replay exactly.
2. **KD-174 two-layer truth cell** — both layers witnessed fresh on one
   node, matching the KD-174F cell:
   - Layer 1 (request-VERSION gate): Produce v3 → conn killed (crash-only),
     listener still serving immediately after (next produce err=0).
   - Layer 2 (payload layer): magic-2 batch inside Produce v2 → err=0,
     fetch-back verbatim modulo broker offset stamping — with one precision
     the KD-174F wording elides, witnessed here: the broker stamps the base
     offset into BOTH the served wrapper offset field AND the batch's inner
     baseOffset field (bytes 0..7). At base 0 the inner stamp is a no-op,
     which is why earlier lanes' byte-compare passed without exposing it.
3. **Adversarial lying-count** — legacy message set of TWO frames, first
   frame ≥ 61B with `0x00000005` planted at bytes 57..60 (the pre-fix
   recordsCount read; "count=5, 2 entries"): both frames admitted typed
   err=0, hwm advanced by EXACTLY 2 (one per frame, never 5), both entries
   byte-exact on fetch-back. Companion magic-2 face: CRC-valid batch with
   header recordsCount=5 vs 2 real records → typed refusal (produce err=2,
   corrupt-message face), hwm unchanged.
4. **Suites fresh** — `MIX_BUILD_ROOT=_build-kfkv MIX_ENV=test mix test
   test/internal/kafka_exp4_court_test.exs test/internal/kafka_wire_test.exs`
   → `18 passed`, exit 0 (3 more than BK-KFKSKEP's 15 — the repair's own
   tests are in the tree).

## Verification ladder (fresh runs, actual exits)

Node: `SMALT_KAFKA_LOG_DIR=tmp/bkkfkv-kafka-journal MIX_ENV=test
MIX_BUILD_ROOT=_build-kfkv mix run --no-halt scripts/kafka_replay/bkkfkv_boot.exs` (ephemeral
KPORT, seal-on-trigger arm for the seal→kill→restart sequence).

```
$ python3 scripts/kafka_replay/bkkfkv_probe.py 49662 r1
PASS R1 fresh partition (before=0) :: before=0
PASS R1 three mixed-size legacy frames admitted (err=0 each) :: [(0, 0), (0, 1), (0, 2)]
PASS R1 bases consecutive from empty partition :: before=0 [(0, 0), (0, 1), (0, 2)]
PASS R1 hwm exactly 3 (one per legacy frame, never payload-bytes garbage) :: hwm 0->3
PASS R1 pre-restart bytes exact (offset-stamped wrappers concat) :: len=254
PROBE-DONE phase=r1 fails=0    exit 0

$ touch /tmp/bkkfkv-seal-trigger
→ seal result %{"bytes" => 389, "first_seq" => 0, "frames" => 3,
  "last_seq" => 2, "segment" => "seg-00000000000000000000.journal",
  "sha256" => "28de1c30469ac9f0e3cafbf048e4e3059473b6f1576af52d6b710558a64578b7"}

$ (restart same journal dir) → log:
06:55:31.042 info[] [kafka] replayed 3 batch(es) from sealed journal under tmp/bkkfkv-kafka-journal

$ python3 scripts/kafka_replay/bkkfkv_probe.py 50456 r2 /tmp/bkkfkv-state.json
PASS R2 hwm preserved exactly :: 3 vs 3
PASS R2 bytes byte-exact across restart (counts+offsets replay exactly) :: len=254 vs 254
PASS R2 hwm == 3 exactly (counts replayed 1/frame) :: hwm_b=3
PROBE-DONE phase=r2 fails=0    exit 0

$ python3 scripts/kafka_replay/bkkfkv_probe.py 50456 kd     (post-replay node — replayed surface stays sane)
PASS KD1 Produce v3 -> conn killed (crash-only)
PASS KD1 listener still serving after the kill :: err=0 base=5
PASS KD2 magic-2 payload in Produce v2 admitted err=0 :: base=6
PASS KD2 magic-2 fetch-back verbatim (offset stamped) :: err=0 exact=True
PASS KD2 magic-2 hwm advances exactly 1 :: 6->7
PROBE-DONE phase=kd fails=0    exit 0

$ python3 scripts/kafka_replay/bkkfkv_probe.py 50456 adv
PASS ADV lying-count(5)/2-entry legacy batch admitted typed :: err=0 base=10
PASS ADV hwm advances EXACTLY 2 (one per frame), never 5 :: hwm 9->11 (delta=2, want 2)
PASS ADV both entries byte-exact on fetch-back :: err=0 match=True
PASS ADV m2 header count=5 vs 2 records: typed refusal, hwm unchanged :: err=2 hwm 11->11
PROBE-DONE phase=adv fails=0   exit 0

$ MIX_BUILD_ROOT=_build-kfkv MIX_ENV=test mix test test/internal/kafka_exp4_court_test.exs \
    test/internal/kafka_wire_test.exs
Result: 18 passed    exit 0
```

## Typed findings

- **BK-KFKV-1 (LOW, documentation precision)**: the KD-174F "verbatim modulo
  broker offset stamping" wording underspecifies the stamping — the broker
  writes the base offset into the batch's INNER baseOffset field (batch bytes
  0..7) in addition to the served wrapper offset field. At base 0 (every
  prior byte-compare witness produced onto an empty partition) the inner
  stamp is a no-op; at base > 0 it is not. KD2 exact-compare must stamp both.
  Not a defect — the served bytes are correct (CRC still verifies; the
  baseOffset field is CRC-neutral) — a witness-wording correction owed to the
  KD-174F cell.
- **BK-KFKV-2 (LOW, process)**: the BK-KFKC shim in
  `lib/smalt/messaging/kafka/records.ex` (magic-first `count/1` dispatch +
  legacy F3 cross-check in `parse_records/1`) carries NO `# KD-COVERS:` token
  and the KFKSKEP legacy-count defect ("candidate KD-176") has no KD row yet
  (nothing in `KNOWN_DIVERGENCES.md` beyond KFKSKEP's receipt). Per repo law
  a shim landing in `lib/` carries `# KD-COVERS: KD-nn`; the KD row +
  token + `kd_flip` flow are owed by the owner lane.

## Falsifiers

- Replay law: restart must restore counts/offsets/bytes exactly — holds
  (3/3/254B, byte-exact, hwm 3).
- KD-174 layer-1: out-of-matrix Produce v3 must kill crash-only and the
  listener must survive — holds.
- KD-174 layer-2: magic-2 payload in Produce v2 must be admitted and served
  verbatim modulo offset stamping — holds (with BK-KFKV-1 precision).
- Legacy lying-count: hwm must advance one per frame, never the lie; a
  magic-2 lying header must be typed-refused with hwm unchanged — both hold.

## Standing

ALIVE: every assigned leg witnessed fresh on the current tree, all exits 0.
BK-KFKC's receipt was pending at write time; this lane verifies the tree
(the repair is present and behaves). BK-KFKC2 (parallel verifier) receipt
`bkkfkc2-legacy-verify.md` also not landed at write time; no overlap — its
witnessed legs (K1 real-client, K2 single-frame 0x42424242, K2b single-frame
m2 lie, K5 generic replay) are disjoint shapes from this lane's (mixed-size
multi-frame replay series, KD-174 two-layer, count=5/2-entry legacy lie +
m2 count=5/2-records typed refusal).
