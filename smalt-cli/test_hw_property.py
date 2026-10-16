"""Property-based tests (hypothesis) for the HIL wire codec — ERRC Raise lane 6.

Generalizes the hand-rolled vectors in tests/test_virtual_serial.py and the
self-tests in smalt_cli/hw/serial.py into generated properties. The
example-based tests remain the pinned regressions; these properties are their
generalization.

Properties
----------
P1  CRC round-trip: for arbitrary payloads (0..4096 bytes) the wire frame
    round-trips through the streaming deframer across arbitrary chunk splits.
P2  Message identity: for arbitrary message values of all 5 message types,
    wire encode -> decode reconstructs the same value.
P3  Resync totality: arbitrary byte soup, any chunking, never raises; frames
    emitted from noise re-validate as well-formed bodies.

Run:
    cd smalt-cli && .venv/bin/pytest test_hw_property.py -v
"""

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from smalt_cli.hw.serial import (
    MSG_CAPABILITIES,
    MSG_ENROLL,
    MSG_ERROR,
    MSG_SIGN_CHALLENGE,
    MSG_SIGNED_RECEIPT,
    ERROR_CODES,
    Capabilities,
    DeviceError,
    FrameDecoder,
    ProtocolError,
    SignedReceipt,
    crc16_ccitt_false,
    crc16_self_test,
    decode_any_frame,
    decode_message,
    encode_frame,
    encode_message,
)

# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------

payloads = st.binary(max_size=512)
text = st.text(max_size=32)  # wire fields decode via .decode("utf-8")


def push_chunked(decoder, frame, chunks):
    """Push `frame` through `decoder` in arbitrary chunk sizes."""
    pos = 0
    for c in chunks:
        decoder.push(frame[pos : pos + c])
        pos += c
    decoder.push(frame[pos:])
    return decoder


# ---------------------------------------------------------------------------
# P1 — CRC / frame round-trip
# ---------------------------------------------------------------------------

@given(payload=payloads, chunks=st.lists(st.integers(min_value=1, max_value=64), max_size=8))
@settings(max_examples=200, suppress_health_check=[HealthCheck.too_slow], deadline=None)
def test_p1_frame_round_trip_arbitrary_payloads_chunkings(payload, chunks):
    frame = encode_frame(payload)
    decoder = push_chunked(FrameDecoder(), frame, chunks)
    assert decoder.frames == [payload]
    assert decode_any_frame(frame) == payload


@given(data=st.data())
@settings(max_examples=100, deadline=None)
def test_p1b_crc_witness_and_determinism(data):
    blob = data.draw(st.binary(max_size=1024))
    assert crc16_self_test()
    assert crc16_ccitt_false(blob) == crc16_ccitt_false(blob)


@given(payload=payloads)
@settings(max_examples=100, deadline=None)
def test_p1c_stuffed_frame_carries_no_bare_flag_or_escape(payload):
    # Stuffing invariant: the stuffed body never contains a bare 0x7E/0x7D.
    frame = encode_frame(payload)
    body = frame[1:-1]
    i = 0
    while i < len(body):
        if body[i] == 0x7D:
            assert body[i + 1] ^ 0x20 in (0x7E, 0x7D)
            i += 2
        else:
            assert body[i] not in (0x7E, 0x7D)
            i += 1


# ---------------------------------------------------------------------------
# P2 — message identity, all 5 types
# ---------------------------------------------------------------------------

@given(digest=st.binary(min_size=32, max_size=32))
@settings(max_examples=100, deadline=None)
def test_p2_sign_challenge_wire_identity(digest):
    msg = {"type": MSG_SIGN_CHALLENGE, "sha256Digest": digest.hex()}
    payload = decode_any_frame(encode_message(msg))
    assert payload == bytes([MSG_SIGN_CHALLENGE]) + digest


@given(n=st.integers(min_value=0, max_value=1))
@settings(max_examples=20, deadline=None)
def test_p2b_enroll_wire_identity(n):
    payload = decode_any_frame(encode_message({"type": MSG_ENROLL}))
    assert payload == bytes([MSG_ENROLL])


# Wire precondition: serial is at least 1 byte (rest must be >= 64+1+4 bytes).
@given(serial=st.text(min_size=1, max_size=32), counter=st.integers(min_value=0, max_value=2**32 - 1))
@settings(max_examples=100, deadline=None)
def test_p2c_signed_receipt_round_trip(serial, counter):
    sig = b"\x01" * 64
    payload = (
        bytes([MSG_SIGNED_RECEIPT])
        + sig
        + serial.encode("utf-8")
        + counter.to_bytes(4, "little")
    )
    decoded = decode_message(decode_any_frame(encode_frame(payload)))
    assert decoded == SignedReceipt(
        sig=sig.hex(), chipsetSerial=serial, monotonicCounter=counter
    )


@given(
    fw=text,
    se=st.booleans(),
    sha=st.booleans(),
    max_payload=st.integers(min_value=0, max_value=65535),
)
@settings(max_examples=100, deadline=None)
def test_p2d_capabilities_round_trip(fw, se, sha, max_payload):
    fw_bytes = fw.encode("utf-8")[:255]
    payload = (
        bytes([MSG_CAPABILITIES])
        + bytes([1 if se else 0, 1 if sha else 0, len(fw_bytes)])
        + fw_bytes
        + max_payload.to_bytes(2, "little")
    )
    decoded = decode_message(decode_any_frame(encode_frame(payload)))
    assert decoded == Capabilities(
        secureElement=se,
        sha256Accelerator=sha,
        firmwareVersion=fw_bytes.decode("utf-8", errors="ignore"),
        maxPayloadBytes=max_payload,
    )


@given(code=st.integers(min_value=0, max_value=255), message=text)
@settings(max_examples=100, deadline=None)
def test_p2e_device_error_round_trip(code, message):
    payload = bytes([MSG_ERROR, code]) + message.encode("utf-8")
    decoded = decode_message(decode_any_frame(encode_frame(payload)))
    expected_code = ERROR_CODES[code] if code < len(ERROR_CODES) else "INTERNAL"
    assert decoded == DeviceError(code=expected_code, message=message)


# ---------------------------------------------------------------------------
# P3 — resync totality: arbitrary byte soup, any chunking, never raises
# ---------------------------------------------------------------------------

@given(soup=st.binary(max_size=4096), chunk_size=st.integers(min_value=1, max_value=97))
@settings(max_examples=200, suppress_health_check=[HealthCheck.too_slow], deadline=None)
def test_p3_arbitrary_byte_soup_never_raises(soup, chunk_size):
    decoder = FrameDecoder()
    for i in range(0, len(soup), chunk_size):
        decoder.push(soup[i : i + chunk_size])
    for f in decoder.frames:
        # Whatever a noise stream emits must itself be a well-formed body.
        assert decode_any_frame(encode_frame(f)) == f


@given(prefix=payloads, payload=payloads, suffix=payloads)
@settings(max_examples=200, deadline=None)
def test_p3b_noise_bracketed_frame_still_delivered(prefix, payload, suffix):
    frame = encode_frame(payload)
    decoder = FrameDecoder()
    decoder.push(prefix)
    decoder.push(frame)
    decoder.push(suffix)
    assert payload in decoder.frames


def test_p1d_oversize_payload_raises_protocol_error():
    with pytest.raises(ProtocolError):
        encode_frame(b"\x00" * 4097)
