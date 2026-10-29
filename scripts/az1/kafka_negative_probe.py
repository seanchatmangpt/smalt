#!/usr/bin/env python3
"""AZ-1 negative probe: crash-only law witness (raw TCP, no client lib).

Legs:
  1. bad CRC batch -> server MUST kill the connection (recv -> b"")
  2. Produce v9 (first flexible Produce version) -> server MUST kill the
     connection (the lane falsifier, named in Conn's moduledoc)

Exit 0 = both kills witnessed; nonzero = FAIL.
"""
import socket
import struct
import sys


def recv_closed(sock, timeout=5.0):
    sock.settimeout(timeout)
    try:
        data = sock.recv(4096)
        return data
    except socket.timeout:
        return None  # server answered instead of killing -> fail leg


def api_versions_ok(sock, corr):
    # request: size, key=18, ver=0, corr, client_id ""
    body = struct.pack(">hhih", 18, 0, corr, 0)
    sock.sendall(struct.pack(">i", len(body)) + body)
    hdr = recv_exact(sock, 8)
    if hdr is None:
        return False
    size, corr2 = struct.unpack(">ii", hdr)
    payload = recv_exact(sock, size - 4)
    return payload is not None and struct.unpack(">h", payload[:2])[0] == 0


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def main():
    port = int(sys.argv[1])
    ok = True

    # -- leg 1: bad CRC kills
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    if not api_versions_ok(s, 1):
        print("FAIL leg1 no apiversions")
        return 1
    batch = bytearray(61)
    batch[16] = 2  # magic = 2 (byte 16: 8 baseOffset + 4 batchLen + 4 leaderEpoch)
    batch[17:21] = struct.pack(">I", 0xDEADBEEF)  # crc field, wrong value
    msgset = struct.pack(">qi", 0, 61) + bytes(batch)
    # produce request: acks, timeout, 1 topic, 1 partition, set
    topic = b"kafka"
    req_body = struct.pack(
        ">hi", 1, 5000) + struct.pack(">i", 1) \
        + struct.pack(">h", len(topic)) + topic \
        + struct.pack(">i", 1) + struct.pack(">i", 0) \
        + struct.pack(">i", len(msgset)) + msgset
    header = struct.pack(">hhih", 0, 2, 7, 0)  # key=0 produce, ver=2, corr=7
    req = struct.pack(">i", len(header) + len(req_body)) + header + req_body
    s.sendall(req)
    closed = recv_closed(s) == b""
    print(("PASS" if closed else "FAIL") + " bad-CRC conn killed")
    ok = ok and closed
    s.close()

    # -- leg 2: Produce v9 kills (lane falsifier)
    s2 = socket.create_connection(("127.0.0.1", port), 5)
    if not api_versions_ok(s2, 1):
        s2.close()
        print("FAIL leg2 no apiversions")
        return 1
    header9 = struct.pack(">hhih", 0, 9, 8, 0)  # produce v9
    req9 = struct.pack(">i", len(header9) + 10) + header9 + b"\x00" * 10
    s2.sendall(req9)
    closed9 = recv_closed(s2) == b""
    print(("PASS" if closed9 else "FAIL") + " produce-v9 conn killed")
    ok = ok and closed9
    s2.close()
    print("SUMMARY: " + ("2/2 PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
