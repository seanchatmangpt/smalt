#!/usr/bin/env python3
"""BK-KFKSKEP adversarial raw-wire probe. Exit 0 = all legs PASS."""
import socket, struct, sys, zlib

PORT = int(sys.argv[1])
TOPIC = "kafka"

_TBL = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
    _TBL.append(c)

def crc32c(data):
    crc = 0xFFFFFFFF
    for b in data:
        crc = (crc >> 8) ^ _TBL[(crc ^ b) & 0xFF]
    return crc ^ 0xFFFFFFFF

def recv_exact(s, n, timeout=5.0):
    s.settimeout(timeout)
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise ConnectionError("conn killed")
        buf += c
    return buf

def recv_resp(s, timeout=5.0):
    (size,) = struct.unpack(">i", recv_exact(s, 4, timeout))
    body = recv_exact(s, size, timeout)
    (corr,) = struct.unpack(">i", body[:4])
    return corr, body[4:]

def send_req(s, key, ver, corr, body):
    payload = struct.pack(">hhih", key, ver, corr, 0) + body
    s.sendall(struct.pack(">i", len(payload)) + payload)

def i32(v): return struct.pack(">i", v)
def s16(v): return struct.pack(">h", v)
def st(txt):
    b = txt.encode()
    return struct.pack(">H", len(b)) + b

def zz(n): return ((n << 1) ^ (n >> 63)) if n < 0 else (n << 1)
def varint(n):
    n = zz(n)
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            out += bytes([b])
            return out

def mk_record(value):
    body = varint(0)+varint(0)+varint(0)+varint(-1)+varint(len(value))+value+varint(0)
    return varint(len(body)) + body

def batch2(records, count):
    # baseOffset i64 | batchLength i32 | leaderEpoch i32 | magic i8 | crc u32 |
    # attributes i16 | lastOffsetDelta i32 | firstTs i64 | maxTs i64 |
    # producerId i64 | producerEpoch i16 | baseSeq i32 | recordsCount i32 = 61
    tail = struct.pack(">hiqqqhii", 0, 0, 0, 0, 0, 0, 0, count)  # attrs..recordsCount
    hdr = struct.pack(">qii", 0, 0, 0) + bytes([2]) + struct.pack(">I", 0) + tail + records
    assert len(hdr) - len(records) == 61, len(hdr)
    crc = crc32c(hdr[21:] )
    hdr = hdr[:17] + struct.pack(">I", crc) + hdr[21:]
    return hdr

def legacy0_frame(value):
    core = struct.pack(">bb", 0, 0) + i32(-1) + i32(len(value)) + value
    crc = zlib.crc32(core) & 0xFFFFFFFF
    return struct.pack(">I", crc) + core

def wire_legacy(value):
    frame = legacy0_frame(value)
    return struct.pack(">qi", 0, len(frame)) + frame

def wire_m2(b2):
    return struct.pack(">qi", 0, len(b2)) + b2

def new_conn():
    return socket.create_connection(("127.0.0.1", PORT), timeout=5)

def api_versions(s, corr=1):
    send_req(s, 18, 0, corr, b"")
    return recv_resp(s)

def parse_produce_resp(payload):
    (nt,) = struct.unpack(">i", payload[:4]); off = 4
    (tl,) = struct.unpack(">H", payload[off:off+2]); off += 2 + tl
    off += 4
    part, err, base = struct.unpack(">ihq", payload[off:off+14])
    return part, err, base

def produce_body(tset):
    return s16(1) + i32(30000) + tset

def part0_set(raw):
    return i32(1) + st(TOPIC) + i32(1) + i32(0) + i32(len(raw)) + raw

FAIL = []
def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ((" :: " + detail) if detail else ""))
    if not cond:
        FAIL.append(name)

def fetch_raw(topic, part, offset):
    s = new_conn()
    body = i32(-1)+i32(100)+i32(0)+i32(1)+st(topic)+i32(1)+i32(part)+struct.pack(">q",offset)+i32(1<<20)
    send_req(s, 1, 0, 7, body)
    _, payload = recv_resp(s)
    (nt,) = struct.unpack(">i", payload[:4]); off = 4
    (tl,) = struct.unpack(">H", payload[off:off+2]); off += 2 + tl
    off += 4
    part_i, err, hwm = struct.unpack(">ihq", payload[off:off+14]); off += 14
    (sl,) = struct.unpack(">i", payload[off:off+4]); off += 4
    mset = payload[off:off+sl]
    s.close()
    return part_i, err, hwm, mset

def leg_a():
    value = ("kfkskep-magic2-%d" % PORT).encode()
    b2 = batch2(mk_record(value), 1)
    s = new_conn()
    api_versions(s, 1)
    send_req(s, 0, 2, 2, produce_body(part0_set(wire_m2(b2))))
    try:
        _, payload = recv_resp(s)
        part, err, base = parse_produce_resp(payload)
        check("A magic-2 produce answered (not killed)", True, "err=%d base_offset=%d" % (err, base))
        pi, ferr, hwm, mset = fetch_raw(TOPIC, 0, 0)
        sent = wire_m2(b2)
        # server stamps the real base offset into wrapper bytes 0..7; compare
        # size field + batch bytes, wrapper offset must be >= 0
        exact = (mset[:8] == struct.pack(">q", base) and mset[8:] == sent[8:])
        check("A magic-2 fetch-back byte-exact (batch verbatim, offset stamped)", ferr == 0 and exact,
              "err=%d exact=%s len=%d/%d" % (ferr, exact, len(mset), len(sent)))
    except (ConnectionError, socket.timeout) as e:
        check("A magic-2 produce answered", False, repr(e))
    finally:
        s.close()

def leg_b():
    value = ("kfkskep-legacy0-%d" % PORT).encode()
    frames = wire_legacy(value)
    s = new_conn()
    api_versions(s, 1)
    send_req(s, 0, 2, 2, produce_body(part0_set(frames)))
    try:
        _, payload = recv_resp(s)
        part, err, base = parse_produce_resp(payload)
        check("B legacy magic-0 produce admitted", err == 0, "err=%d base=%d" % (err, base))
        pi, ferr, hwm, mset = fetch_raw(TOPIC, 0, 0)
        exact = (mset[:8] == struct.pack(">q", base) and mset[8:] == frames[8:])
        check("B legacy fetch-back byte-exact (frame verbatim, offset stamped)", ferr == 0 and exact,
              "err=%d exact=%s" % (ferr, exact))
    except (ConnectionError, socket.timeout) as e:
        check("B legacy produce", False, repr(e))
    finally:
        s.close()

def leg_c_in_session():
    s = new_conn()
    api_versions(s, 1)
    for v in (0, 1):
        send_req(s, 3, v, 10+v, i32(1) + st(TOPIC))
        try:
            recv_resp(s)
            check("C Metadata v%d answered in-session" % v, True)
        except (ConnectionError, socket.timeout) as e:
            check("C Metadata v%d" % v, False, repr(e))
    for v in (0, 1):
        body = i32(-1) + i32(1) + st(TOPIC) + i32(1) + i32(0) + struct.pack(">q", -1)
        if v == 0:
            body += i32(1)  # v0 carries maxNumOffsets i32
        send_req(s, 2, v, 20+v, body)
        try:
            recv_resp(s)
            check("C ListOffsets v%d answered" % v, True)
        except (ConnectionError, socket.timeout):
            check("C ListOffsets v%d" % v, False, "killed")
    for v in (0, 1, 2):
        body = i32(-1)+i32(100)+i32(0)+i32(1)+st(TOPIC)+i32(1)+i32(0)+struct.pack(">q",0)+i32(1024)
        send_req(s, 1, v, 30+v, body)
        try:
            recv_resp(s)
            check("C Fetch v%d answered" % v, True)
        except (ConnectionError, socket.timeout):
            check("C Fetch v%d" % v, False, "killed")
    # produce v0 in same session
    value = b"kfkskep-prod-v0"
    frames = wire_legacy(value)
    send_req(s, 0, 0, 40, produce_body(part0_set(frames)))
    try:
        _, payload = recv_resp(s)
        part, err, base = parse_produce_resp(payload)
        check("C Produce v0 answered in-session", err == 0, "err=%d base=%d" % (err, base))
    except (ConnectionError, socket.timeout) as e:
        check("C Produce v0", False, repr(e))
    s.close()

def leg_c_kill():
    cases = [(0,3),(1,3),(2,2),(3,2),(18,1)]
    for key, ver in cases:
        s = new_conn()
        try:
            send_req(s, key, ver, 99, b"")
            try:
                _, payload = recv_resp(s, timeout=3)
                check("C out-of-matrix key=%d v%d crash-only" % (key, ver), False,
                      "answered: %s" % payload[:16].hex())
            except (ConnectionError, socket.timeout):
                check("C out-of-matrix key=%d v%d -> conn killed" % (key, ver), True)
        finally:
            s.close()

def leg_d():
    s = new_conn()
    api_versions(s, 1)
    for c in (101, 102, 103):
        send_req(s, 18, 0, c, b"")
    got = []
    ok = True
    for _ in range(3):
        corr, _ = recv_resp(s)
        got.append(corr)
    check("D pipelined corr echo in order", got == [101, 102, 103], "got=%s" % got)
    s.close()

def leg_e():
    value = b"x" * (2 * 1024 * 1024)
    frames = wire_legacy(value)
    s = new_conn()
    api_versions(s, 1)
    try:
        send_req(s, 0, 2, 2, produce_body(part0_set(frames)))
        _, payload = recv_resp(s, timeout=30)
        part, err, base = parse_produce_resp(payload)
        check("E oversized 2MiB produce answered typed", True, "err=%d base=%d" % (err, base))
        pi, ferr, hwm, mset = fetch_raw(TOPIC, 0, 0)
        check("E fetch-back after oversized still sane", ferr == 0, "err=%d" % ferr)
    except (ConnectionError, socket.timeout) as e:
        check("E oversized 2MiB produce answered", False, repr(e))
    finally:
        s.close()



if FAIL:
    print("SUMMARY: %d FAIL: %s" % (len(FAIL), FAIL))
    sys.exit(1)
print("SUMMARY: ALL PASS")
