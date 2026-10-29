# Receipt: BK-KLVD — BK-KFKV residue lane (dual-stamp verify + probe relocation + courts)

- **Lane**: BK-KLVD (`/Users/sac/smalt`, canonical checkout, `MIX_BUILD_ROOT=_build-bklvd`)
- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22

## 1. BK-KFKV-1 closed — dual-stamp amendment verified on disk

`docs/jira/v26.10.22/KNOWN_DIVERGENCES.md` KD-174's truth cell carries the
KD-KLV amendment verbatim (grep on disk, this window):

> KD-174F dual-stamp precision (BK-KFKV-1, lane KD-KLV 2026-10-22): the broker
> stamps the base offset into BOTH the served wrapper offset field AND the
> batch's inner baseOffset field (batch bytes 0..7, CRC-neutral) — a no-op at
> base 0 ... exact-compare witnesses at base > 0 must stamp both

Matches BK-KFKV-1's precision exactly (wrapper offset + inner baseOffset bytes
0..7, CRC-neutral, no-op at base 0, both stamps required at base > 0). The
amendment also appears in the KD-KLV commit message. BK-KFKV-1: CLOSED.

## 2. Probe scratch relocated to tracked scripts/ (BK-BMIR class)

`bkkfkv-replay-verify.md`'s replay ladder referenced `tmp/bkkfkv_boot.exs` +
`tmp/bkkfkv_probe.py` (untracked scratch — replay would break on tmp cleanup).
(For contrast: `bkkfkc-legacy-count.md`'s replay is NOT scratch-dependent — its
real-client probe is already tracked at `scripts/az1/kafka_probe.py`, and
`KAFKALIB=tmp/kafkalib` is a regenerable pip target, not a source. `tmp/`
kafka journal dirs referenced in receipts are runtime state, also regenerable.)
`bkkfkc2_probe.py` was NOT relocated: `bkkfkc2-legacy-verify.md` is not yet
landed (owner lane holds it), so its receipt has no landed replay ladder
referencing scratch yet.

Relocated, with a real full-ladder re-run (not a copy-and-claim):

- `scripts/kafka_replay/bkkfkv_boot.exs` (boot + seal-trigger arm; probe dep
  `bkkfkskep_wplib.py` relocated alongside — the probe imports it by name)
- `scripts/kafka_replay/bkkfkv_probe.py`
- `scripts/kafka_replay/bkkfkskep_wplib.py`
- `bkkfkv-replay-verify.md` path references updated `tmp/…` →
  `scripts/kafka_replay/…` (5 command lines + Mode line)

Fresh full ladder on the relocated files (lane-private journal
`tmp/bklvd-kafka-journal`, ephemeral KPORT, `MIX_ENV=test`):

```
$ SMALT_TEST_KAFKA_PORT=52592 … mix run --no-halt scripts/kafka_replay/bkkfkv_boot.exs
KPORT=52592
$ python3 scripts/kafka_replay/bkkfkv_probe.py 52592 r1
PASS R1 fresh partition (before=0) :: before=0
PASS R1 three mixed-size legacy frames admitted (err=0 each) :: [(0, 0), (0, 1), (0, 2)]
PASS R1 bases consecutive from empty partition :: before=0 [(0, 0), (0, 1), (0, 2)]
PASS R1 hwm exactly 3 (one per legacy frame, never payload-bytes garbage) :: hwm 0->3
PASS R1 pre-restart bytes exact (offset-stamped wrappers concat) :: len=254
PROBE-DONE phase=r1 fails=0    exit 0
$ touch /tmp/bkkfkv-seal-trigger →
%{"bytes" => 389, "frames" => 3, "last_seq" => 2,
  "sha256" => "c0ec57872e8ead11dfd95a8bfda0ddfca61f39901e7d595341e0b2b7afa9d289"}
(R2 boot: [kafka] replayed 3 batch(es) from sealed journal under tmp/bklvd-kafka-journal)
$ python3 scripts/kafka_replay/bkkfkv_probe.py 52831 r2 /tmp/bkkfkv-state.json
PASS R2 hwm preserved exactly :: 3 vs 3
PASS R2 bytes byte-exact across restart :: len=254 vs 254
PASS R2 hwm == 3 exactly :: hwm_b=3
PROBE-DONE phase=r2 fails=0    exit 0
$ python3 scripts/kafka_replay/bkkfkv_probe.py 52831 kd
PASS KD1 Produce v3 -> conn killed (crash-only)
PASS KD1 listener still serving after the kill :: err=0 base=3
PASS KD2 magic-2 payload in Produce v2 admitted err=0 :: base=4
PASS KD2 magic-2 fetch-back verbatim (offset stamped) :: err=0 exact=True
PASS KD2 magic-2 hwm advances exactly 1 :: 4->5
PROBE-DONE phase=kd fails=0    exit 0
$ python3 scripts/kafka_replay/bkkfkv_probe.py 52831 adv
PASS ADV lying-count(5)/2-entry legacy batch admitted typed :: err=0 base=6
PASS ADV hwm advances EXACTLY 2 (one per frame), never 5 :: hwm 5->7 (delta=2, want 2)
PASS ADV both entries byte-exact on fetch-back :: err=0 match=True
PASS ADV m2 header count=5 vs 2 records: typed refusal, hwm unchanged :: err=2 hwm 7->7
PROBE-DONE phase=adv fails=0   exit 0
```

All 14 probe legs PASS on the relocated scripts — replay is self-contained in
tracked files. One process note: the boot script seals-and-exits on the
presence of `/tmp/bkkfkv-seal-trigger` — a stray trigger from an earlier
attempt caused a 0-frame empty seal; the ladder must start trigger-free
(disclosed here, no code change).

## 3. Courts fresh

```
$ SMALT_TEST_KAFKA_PORT=39461 MIX_ENV=test MIX_BUILD_ROOT=_build-bklvd \
    mix test test/internal/kafka_exp4_court_test.exs test/internal/kafka_wire_test.exs
Result: 19 passed    exit 0
```

## Standing

ALIVE: KD-174 dual-stamp amendment verified on disk (BK-KFKV-1 closed); the
BK-KFKV replay ladder relocated to tracked `scripts/kafka_replay/` and proven
end-to-end (14/14 legs + byte-exact seal/replay) on this tree; exp4 + wire
courts 19 passed, exit 0. Only remaining residue is `tmp/` runtime state
(journals, logs, seal trigger), regenerable by construction.
