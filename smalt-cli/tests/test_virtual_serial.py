"""Cross-language HIL court: Python host drives the Elixir virtual device
through the real SerialTransport.transact over a raw-mode pty.

- enroll -> CAPABILITIES fw "sim-0.1+ed25519"
- sign -> SIGNED_RECEIPT, strictly increasing counter, 64-byte sig
- bad-CRC frame resync on the wire
- codec parity: same 0x29B1 vector + byte-identical frames as the Elixir
  codec court (test/smalt/hw_test.exs) — shared witness constants.
"""

import hashlib
import sys

import pytest

sys.path.insert(0, __file__.rsplit("/tests/", 1)[0])

from smalt_cli.hw.serial import (
    MSG_ENROLL,
    MSG_SIGN_CHALLENGE,
    SerialTransport,
    crc16_ccitt_false,
    encode_frame,
)
from smalt_cli.hw.sim_host import SimHost

pytestmark = pytest.mark.skipif(
    sys.platform != "darwin" and sys.platform != "linux",
    reason="pty-based virtual device needs macOS/Linux",
)


@pytest.fixture(scope="module")
def substrate():
    """Shadow tests/conftest.py's autouse session fixture: this lane needs
    no substrate — its dependency is the pty + Elixir device process."""
    yield


@pytest.fixture(scope="module")
def sim():
    host = SimHost()
    host.start()
    yield host
    host.stop()


def test_enroll_capabilities(sim):
    t = sim.transport()
    env = t.transact({"type": MSG_ENROLL})
    assert env["status"] == "OK"
    caps = env["value"]
    assert caps.firmwareVersion == "sim-0.1+ed25519"
    assert caps.secureElement is True
    assert caps.sha256Accelerator is True
    assert caps.maxPayloadBytes == 4096


def test_sign_receipt_increasing_counter(sim):
    t = sim.transport()
    digest = hashlib.sha256(b"test-challenge").hexdigest()
    r1 = t.transact({"type": MSG_SIGN_CHALLENGE, "sha256Digest": digest})
    r2 = t.transact({"type": MSG_SIGN_CHALLENGE, "sha256Digest": digest})
    for r in (r1, r2):
        assert r["status"] == "OK"
        assert r["value"].type == 0x02
        assert len(r["value"].sig) == 128  # 64 bytes hex
    assert r1["value"].monotonicCounter < r2["value"].monotonicCounter
    assert r1["value"].chipsetSerial.startswith("SIM-SMALT-")


def test_bad_crc_resync_on_the_wire(sim):
    t = sim.transport()
    good = encode_frame(bytes([MSG_ENROLL]))
    corrupt = bytes([good[0], good[1], good[2] ^ 0xFF]) + good[3:]
    # real wire bytes: device decoder must drop the bad frame and resync
    t._port.write(corrupt)
    env = t.transact({"type": MSG_ENROLL})
    assert env["status"] == "OK"
    assert env["value"].firmwareVersion == "sim-0.1+ed25519"


def test_codec_witness_parity():
    """Same witnesses asserted in test/smalt/hw_test.exs (Elixir side)."""
    assert crc16_ccitt_false(b"123456789") == 0x29B1
    assert encode_frame(bytes([MSG_ENROLL])).hex().upper() == "7E010003CFCB7E"
    assert (
        encode_frame(bytes([0x7E, 0x7D, 0xFF, 0x00])).hex().upper()
        == "7E04007D5E7D5DFF0038717E"
    )
    payload = bytes([0x01]) + bytes.fromhex("AA" * 32)
    assert encode_frame(payload).hex().upper() == "7E210001" + "AA" * 32 + "C1597E"
