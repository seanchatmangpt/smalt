#!/usr/bin/env python3
"""BK-KFKV verify probe (lane BK-KFKV). Exit 0 = all legs PASS.

Unique slice (distinct from BK-KFKC2's K1/K2/K2b/K5 single-frame legs):
  R1  legacy journal-replay LAW, mixed-size series (12B / 60B / 99B values;
      frames 33B / 81B / 120B — two frames >= 61B, i.e. values >= 47B, the
      pre-fix corruption shape). Phase A: produce 3 frames, record
      hwm/offsets/bytes pre-restart.
  R2  phase B (separate node invocation = post-restart): fetch-back from
      offset 0; hwm and per-offset bytes must replay EXACTLY (hwm exactly 3
      — one per legacy frame, never garbage counts).
  KD1 Produce v3 (out-of-matrix) -> crash-only kill (conn closed), listener
      still serving afterwards (KD-174F layer-1: request-VERSION gate).
  KD2 magic-2 payload inside accepted Produce v2 -> err=0, fetch-back
      verbatim modulo base-offset stamping (KD-174F layer-2: payload layer).
  ADV legacy lying-count adversarial: TWO legacy frames in one message set,
      first frame's bytes 57..60 encode count=5 ("declared" count=5, 2
      entries) -> both admitted typed, hwm advances by EXACTLY 2 (one per
      frame, never 5), both values byte-exact on fetch-back. Plus the magic-2
      face: header count=5 vs 2 real records -> typed refusal, hwm unchanged.
"""
import socket, struct, sys, zlib, json, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bkkfkskep_wplib import (
    recv_resp, send_req, i32, s16, batch2, mk_record,
    legacy0_frame, wire_legacy, wire_m2, new_conn, api_versions,
    parse_produce_resp, produce_body, part0_set, fetch_raw, check, FAIL,
)

PORT = int(sys.argv[1])
PHASE = sys.argv[2] if len(sys.argv) > 2 else "r1"

TOPIC = "kafka"
STATE = "/tmp/bkkfkv-state.json"


def hwm_of(part=0):
    _, err, hwm, _ = fetch_raw(TOPIC, part, 0)
    assert err == 0, f"fetch err={err}"
    return hwm


def produce_raw(raw, ver=0, corr=2):
    """Produce raw message-set bytes via Produce `ver`; return (err, base)."""
    s = new_conn()
    try:
        api_versions(s, 1)
        send_req(s, 0, ver, corr, produce_body(part0_set(raw)))
        _, payload = recv_resp(s)
        _, err, base = parse_produce_resp(payload)
        return err, base
    finally:
        s.close()


def fetch_all(part=0):
    _, err, hwm, mset = fetch_raw(TOPIC, part, 0)
    return err, hwm, mset


if PHASE == "r1":
    v1 = b"kfkv-small-1"                 # 12B value -> 33B frame
    v2 = b"kfkv-wide-2-" + b"W" * 50     # 60B value -> 81B frame (>= 61B)
    v3 = b"kfkv-wide-3-" + b"Z" * 90     # 99B value -> 120B frame
    frames = [wire_legacy(v) for v in (v1, v2, v3)]
    before = hwm_of()
    check("R1 fresh partition (before=0)", before == 0, f"before={before}")
    results = []
    for f in frames:
        if len(f) >= 61:
            assert f[57:61] in (b"WWWW", b"ZZZZ"), f[57:61]
        err, base = produce_raw(f, ver=0)
        results.append((err, base))
    err_a, hwm_a, mset_a = fetch_all()
    check("R1 three mixed-size legacy frames admitted (err=0 each)",
          all(e == 0 for e, _ in results), f"{results}")
    check("R1 bases consecutive from empty partition",
          [b for _, b in results] == [before, before + 1, before + 2],
          f"before={before} {results}")
    check("R1 hwm exactly 3 (one per legacy frame, never payload-bytes garbage)",
          hwm_a == before + 3, f"hwm {before}->{hwm_a}")
    check("R1 pre-restart bytes exact (offset-stamped wrappers concat)",
          mset_a == b"".join(struct.pack(">q", before + i) + f[8:]
                             for i, f in enumerate(frames)),
          f"len={len(mset_a)}")
    with open(STATE, "w") as fh:
        json.dump({"hwm_a": hwm_a, "mset_a": mset_a.hex()}, fh)
    print("STATE=%s" % STATE)

elif PHASE == "r2":
    with open(sys.argv[3]) as fh:
        st_ = json.load(fh)
    err_b, hwm_b, mset_b = fetch_all()
    check("R2 hwm preserved exactly", hwm_b == st_["hwm_a"],
          f"{hwm_b} vs {st_['hwm_a']}")
    mset_want = bytes.fromhex(st_["mset_a"])
    check("R2 bytes byte-exact across restart (counts+offsets replay exactly)",
          mset_b == mset_want, f"len={len(mset_b)} vs {len(mset_want)}")
    check("R2 hwm == 3 exactly (counts replayed 1/frame)", hwm_b == 3,
          f"hwm_b={hwm_b}")

elif PHASE == "kd":
    s = new_conn()
    api_versions(s, 1)
    body = s16(1) + i32(30000) + part0_set(wire_legacy(b"kfkv-v3"))
    send_req(s, 0, 3, 9, body)
    killed = False
    try:
        recv_resp(s, timeout=3.0)
    except (ConnectionError, socket.timeout):
        killed = True
    finally:
        s.close()
    check("KD1 Produce v3 -> conn killed (crash-only)", killed)
    err, base = produce_raw(wire_legacy(b"kfkv-after-v3"), ver=0)
    check("KD1 listener still serving after the kill", err == 0,
          f"err={err} base={base}")

    val = b"kfkv-magic2-payload-" + b"M" * 40
    b2 = batch2(mk_record(val), 1)
    before = hwm_of()
    s = new_conn()
    api_versions(s, 1)
    send_req(s, 0, 2, 3, produce_body(part0_set(wire_m2(b2))))
    try:
        _, payload = recv_resp(s)
        _, err, base = parse_produce_resp(payload)
        check("KD2 magic-2 payload in Produce v2 admitted err=0", err == 0,
              f"base={base}")
        _, ferr, hwm2, mset = fetch_raw(TOPIC, 0, base)
        sent = wire_m2(b2)
        # served shape: offset(8) + size(4) + batch; broker stamps base into
        # BOTH the wrapper offset field AND the batch's inner baseOffset
        # (bytes 0..7) — verbatim modulo offset stamping (KD-174F wording).
        batch, want = mset[12:], sent[12:]
        exact = (mset[:8] == struct.pack(">q", base)
                 and mset[8:12] == sent[8:12]
                 and batch[:8] == struct.pack(">q", base)
                 and batch[8:] == want[8:])
        check("KD2 magic-2 fetch-back verbatim (offset stamped)",
              ferr == 0 and exact, f"err={ferr} exact={exact}")
        check("KD2 magic-2 hwm advances exactly 1", hwm2 == before + 1,
              f"{before}->{hwm2}")
    except (ConnectionError, socket.timeout) as e:
        check("KD2 magic-2 payload in Produce v2", False, repr(e))
    finally:
        s.close()

elif PHASE == "adv":
    # legacy frame layout: crc(0..3) magic(4) attrs(5) keyLen(6..9) key(10..13)
    # valueLen(14..17) value(14+..): bytes 57..60 = value[43:47] — plant the
    # count=5 lie exactly there (frame >= 61B iff value >= 47B — the exact
    # pre-fix corruption threshold).
    v_hi = (b"kfkv-adv-" + b"A" * 34 + b"\x00\x00\x00\x05" + b"B" * 16)  # 63B value -> 85B frame
    f1 = legacy0_frame(v_hi)
    assert f1[57:61] == b"\x00\x00\x00\x05", f1[57:61].hex()
    f2 = legacy0_frame(b"kfkv-adv-second")
    raw = (struct.pack(">qi", 0, len(f1)) + f1 +
           struct.pack(">qi", 0, len(f2)) + f2)
    before = hwm_of()
    err, base = produce_raw(raw, ver=2)
    after = hwm_of()
    check("ADV lying-count(5)/2-entry legacy batch admitted typed",
          err == 0, f"err={err} base={base}")
    check("ADV hwm advances EXACTLY 2 (one per frame), never 5",
          after - before == 2, f"hwm {before}->{after} (delta={after-before}, want 2)")
    _, ferr, _, mset = fetch_raw(TOPIC, 0, before)
    want = (struct.pack(">qi", before, len(f1)) + f1 +
            struct.pack(">qi", before + 1, len(f2)) + f2)
    check("ADV both entries byte-exact on fetch-back", ferr == 0 and mset == want,
          f"err={ferr} match={mset == want}")

    b2 = batch2(mk_record(b"kfkv-m2-a") + mk_record(b"kfkv-m2-b"), 5)
    before2 = hwm_of()
    s = new_conn()
    api_versions(s, 1)
    send_req(s, 0, 2, 4, produce_body(part0_set(wire_m2(b2))))
    try:
        _, payload = recv_resp(s)
        _, err2, _ = parse_produce_resp(payload)
        after2 = hwm_of()
        check("ADV m2 header count=5 vs 2 records: typed refusal, hwm unchanged",
              err2 != 0 and after2 == before2,
              f"err={err2} hwm {before2}->{after2}")
    except (ConnectionError, socket.timeout) as e:
        check("ADV m2 header count=5 vs 2 records", False, repr(e))
    finally:
        s.close()

print("PROBE-DONE phase=%s fails=%d" % (PHASE, len(FAIL)))
sys.exit(1 if FAIL else 0)
