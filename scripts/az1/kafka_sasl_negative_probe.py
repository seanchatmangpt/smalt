#!/usr/bin/env python3
"""KD-191 SASL negative probe: crash-only/refusal law witness (raw TCP).

Legs (all against a SASL-required listener, sasl_mechanisms includes
:plain; leg 4 needs :anonymous configured + auth_mode :enforce):
  1. SaslHandshake GSSAPI (unadvertised) -> error 33 + server closes
  2. PLAIN blank password on SaslAuthenticate -> error 58 + server closes
  3. Produce BEFORE auth under sasl_required -> server kills (no answer)
  4. ANONYMOUS authenticate under auth_mode :enforce -> error 58 + close

Exit 0 = all legs witnessed; nonzero = FAIL.
"""
import argparse
import socket
import struct
import sys


def recv_closed(sock, timeout=5.0):
    sock.settimeout(timeout)
    try:
        return sock.recv(4096)
    except socket.timeout:
        return None  # server answered or stayed silent -> leg fails


def recv_exact(sock, n, timeout=5.0):
    sock.settimeout(timeout)
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def response(sock, corr):
    hdr = recv_exact(sock, 8)
    if hdr is None:
        return None
    size, corr2 = struct.unpack(">ii", hdr)
    assert corr2 == corr, f"correlation mismatch {corr2} != {corr}"
    return recv_exact(sock, size - 4)


def request(sock, key, ver, corr, body):
    header = struct.pack(">hhih", key, ver, corr, 0)  # cid ""
    payload = header + body
    sock.sendall(struct.pack(">i", len(payload)) + payload)


def handshake(sock, corr, mech):
    request(sock, 17, 0, corr, struct.pack(">h", len(mech)) + mech)
    return response(sock, corr)


def authenticate(sock, corr, mech, token):
    body = struct.pack(">h", len(mech)) + mech + struct.pack(">i", len(token)) + token
    request(sock, 36, 0, corr, body)
    return response(sock, corr)


def plain_token(user, password, authzid=b""):
    return authzid + b"\x00" + user + b"\x00" + password


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    args = ap.parse_args()
    port = args.port
    ok = True

    def report(label, passed):
        nonlocal ok
        print(("PASS" if passed else "FAIL") + " " + label)
        ok = ok and passed

    # leg 1: GSSAPI handshake -> 33 + close
    s = socket.create_connection(("127.0.0.1", port), 5)
    r = handshake(s, 1, b"GSSAPI")
    passed = r is not None and struct.unpack(">h", r[:2])[0] == 33
    report("leg1 gssapi handshake error-33 answered", passed)
    closed = recv_closed(s) == b""
    report("leg1 gssapi handshake conn killed", closed)
    s.close()

    # leg 2: PLAIN wrong password -> 58 + close
    s = socket.create_connection(("127.0.0.1", port), 5)
    r = handshake(s, 2, b"PLAIN")
    passed = r is not None and struct.unpack(">h", r[:2])[0] == 0
    report("leg2 plain handshake advertises", passed)
    ok = ok and passed
    r = authenticate(s, 3, b"PLAIN", plain_token(b"dev", b""))
    passed = r is not None and struct.unpack(">h", r[:2])[0] == 58
    report("leg2 blank-password error-58 answered", passed)
    closed = recv_closed(s) == b""
    report("leg2 blank-password conn killed", closed)
    s.close()

    # leg 3: produce before auth under sasl_required -> kill, no answer
    s = socket.create_connection(("127.0.0.1", port), 5)
    topic = b"kafka"
    body = (
        struct.pack(">hi", 1, 5000)
        + struct.pack(">i", 1)
        + struct.pack(">h", len(topic))
        + topic
        + struct.pack(">i", 1)
        + struct.pack(">i", 0)
        + struct.pack(">i", 0)
    )
    request(s, 0, 2, 9, body)
    closed = recv_closed(s) == b""
    report("leg3 produce-before-auth killed", closed)
    s.close()

    # leg 4: ANONYMOUS under auth_mode :enforce -> 58 + close
    s = socket.create_connection(("127.0.0.1", port), 5)
    r = handshake(s, 4, b"ANONYMOUS")
    if r is None:
        report("leg4 anonymous handshake advertised", False)
    elif struct.unpack(">h", r[:2])[0] == 0:
        r = authenticate(s, 5, b"ANONYMOUS", b"")
        passed = r is not None and struct.unpack(">h", r[:2])[0] == 58
        report("leg4 anonymous-under-enforce error-58", passed)
        report("leg4 anonymous-under-enforce conn killed", recv_closed(s) == b"")
    else:
        # ANONYMOUS not advertised at all: also a lawful enforce refusal
        report("leg4 anonymous not advertised (refused)", struct.unpack(">h", r[:2])[0] == 33)
        report("leg4 anonymous-not-advertised conn killed", recv_closed(s) == b"")
    s.close()

    print("SUMMARY: " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
