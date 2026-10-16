"""USB-CDC serial transport + wire-format codec.

Codec is exact Python parity with workspace/lib/serial/gateway.ts:
frame [0x7E][len:u16 LE][payload][crc16:u16 LE][0x7E], CRC-16/CCITT-FALSE
(poly 0x1021, init 0xFFFF, no reflection, no xorout) over [len][payload],
byte-stuffing 0x7E -> 0x7D 0x5E, 0x7D -> 0x7D 0x5D (ESC_XOR = 0x20).

pyserial is imported lazily so codec use never requires the dependency;
only opening a real transport does.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

FLAG = 0x7E
ESC = 0x7D
ESC_XOR = 0x20

MAX_PAYLOAD_BYTES = 4096
DEFAULT_BAUD = 115200

MSG_SIGN_CHALLENGE = 0x01
MSG_SIGNED_RECEIPT = 0x02
MSG_ENROLL = 0x03
MSG_CAPABILITIES = 0x04
MSG_ERROR = 0x7F

# device -> host error code table (gateway.ts errorCodeFrom)
ERROR_CODES = (
    "BAD_CRC",
    "BAD_FRAME",
    "UNKNOWN_TYPE",
    "NOT_ENROLLED",
    "BAD_DIGEST",
    "INTERNAL",
)

RESPONSE_TYPES = frozenset({MSG_SIGNED_RECEIPT, MSG_CAPABILITIES, MSG_ERROR})


class ProtocolError(Exception):
    """Raised on malformed wire data (mirrors gateway.ts TypeErrors)."""


# ---------------------------------------------------------------------------
# CRC-16/CCITT-FALSE
# ---------------------------------------------------------------------------

def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def crc16_self_test() -> bool:
    """CRC-16/CCITT-FALSE(b"123456789") must equal 0x29B1 (witnessed vector)."""
    return crc16_ccitt_false(b"123456789") == 0x29B1


# ---------------------------------------------------------------------------
# Frame codec
# ---------------------------------------------------------------------------

def _stuff(data: bytes) -> bytes:
    out = bytearray()
    for b in data:
        if b == FLAG or b == ESC:
            out.append(ESC)
            out.append(b ^ ESC_XOR)
        else:
            out.append(b)
    return bytes(out)


def encode_frame(payload: bytes) -> bytes:
    """[0x7E][len:u16 LE][payload][crc:u16 LE][0x7E], stuffed."""
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise ProtocolError(f"payload {len(payload)} > {MAX_PAYLOAD_BYTES}")
    body = len(payload).to_bytes(2, "little") + payload
    tail = body + crc16_ccitt_false(body).to_bytes(2, "little")
    return bytes([FLAG]) + _stuff(tail) + bytes([FLAG])


class FrameDecoder:
    """Streaming deframer; resynchronizes on the next 0x7E after bad frames."""

    def __init__(self) -> None:
        self.buf = bytearray()
        self.in_frame = False
        self.escaped = False
        self.frames: List[bytes] = []

    def push(self, chunk: bytes) -> None:
        for b in chunk:
            if b == FLAG:
                if self.in_frame and len(self.buf) > 0:
                    self._try_emit()
                self.in_frame = True
                self.buf = bytearray()
                self.escaped = False
                continue
            if not self.in_frame:
                continue  # noise between flags
            if b == ESC:
                self.escaped = True
                continue
            if self.escaped:
                self.buf.append(b ^ ESC_XOR)
                self.escaped = False
            else:
                self.buf.append(b)

    def _try_emit(self) -> None:
        raw = bytes(self.buf)
        self.buf = bytearray()
        self.escaped = False
        if len(raw) < 4:
            return  # need len(2)+crc(2)
        length = raw[0] | (raw[1] << 8)
        if len(raw) != 2 + length + 2:
            return
        body = raw[:-2]
        crc = raw[-2] | (raw[-1] << 8)
        if crc16_ccitt_false(body) != crc:
            return
        self.frames.append(raw[2 : 2 + length])


# ---------------------------------------------------------------------------
# Message <-> bytes
# ---------------------------------------------------------------------------

@dataclass
class SignedReceipt:
    sig: str
    chipsetSerial: str
    monotonicCounter: int
    type: int = MSG_SIGNED_RECEIPT


@dataclass
class Capabilities:
    secureElement: bool
    sha256Accelerator: bool
    firmwareVersion: str
    maxPayloadBytes: int
    type: int = MSG_CAPABILITIES


@dataclass
class DeviceError:
    code: str
    message: str
    type: int = MSG_ERROR


def encode_message(message: Dict[str, Any]) -> bytes:
    mtype = message["type"]
    if mtype == MSG_SIGN_CHALLENGE:
        digest = _hex_to_bytes(message["sha256Digest"])
        if len(digest) != 32:
            raise ProtocolError("sha256Digest must be 32 bytes")
        return encode_frame(bytes([MSG_SIGN_CHALLENGE]) + digest)
    if mtype == MSG_ENROLL:
        return encode_frame(bytes([MSG_ENROLL]))
    raise ProtocolError(f"unknown request type 0x{mtype:02x}")


def decode_message(payload: bytes):
    if not payload:
        raise ProtocolError("empty payload")
    mtype = payload[0]
    rest = payload[1:]
    if mtype == MSG_SIGNED_RECEIPT:
        # [sig: 64 bytes][serial: N bytes utf-8][counter: u32 LE]
        if len(rest) < 64 + 1 + 4:
            raise ProtocolError("SIGNED_RECEIPT truncated")
        return SignedReceipt(
            sig=rest[:64].hex(),
            chipsetSerial=rest[64:-4].decode("utf-8"),
            monotonicCounter=int.from_bytes(rest[-4:], "little"),
        )
    if mtype == MSG_CAPABILITIES:
        # [secureElement:u8][sha256:u8][fwLen:u8][fw:utf-8][maxPayload:u16 LE]
        if len(rest) < 5:
            raise ProtocolError("CAPABILITIES truncated")
        fw_len = rest[2]
        if len(rest) < 3 + fw_len + 2:
            raise ProtocolError("CAPABILITIES truncated")
        return Capabilities(
            secureElement=rest[0] != 0,
            sha256Accelerator=rest[1] != 0,
            firmwareVersion=rest[3 : 3 + fw_len].decode("utf-8"),
            maxPayloadBytes=int.from_bytes(rest[3 + fw_len : 5 + fw_len], "little"),
        )
    if mtype == MSG_ERROR:
        code = ERROR_CODES[rest[0]] if rest and rest[0] < len(ERROR_CODES) else "INTERNAL"
        return DeviceError(code=code, message=rest[1:].decode("utf-8"))
    raise ProtocolError(f"unknown message type 0x{mtype:02x}")


def _hex_to_bytes(hex_str: str) -> bytes:
    if len(hex_str) % 2 != 0 or any(c not in "0123456789abcdefABCDEF" for c in hex_str):
        raise ProtocolError("invalid hex string")
    return bytes.fromhex(hex_str)


# ---------------------------------------------------------------------------
# Transports
# ---------------------------------------------------------------------------

class SerialTransport:
    """Request/response over a pyserial USB-CDC port (115200 8N1 default).

    Errors return a status string, never raise across the boundary —
    parity with gateway.ts GatewayEnvelope.
    """

    def __init__(self, port_path: str, baud: int = DEFAULT_BAUD, timeout_s: float = 5.0):
        import serial  # pyserial, lazy

        self._serial = serial
        self._port = serial.Serial(port_path, baud, timeout=timeout_s, write_timeout=timeout_s)
        self._decoder = FrameDecoder()

    @staticmethod
    def discover() -> List[Dict[str, Any]]:
        import serial.tools.list_ports  # lazy

        return [
            {"device": p.device, "vid": p.vid, "pid": p.pid, "description": p.description}
            for p in serial.tools.list_ports.comports()
        ]

    @property
    def connected(self) -> bool:
        return self._port is not None and self._port.is_open

    def close(self) -> str:
        if not self.connected:
            return "NOT_CONNECTED"
        try:
            self._port.close()
            return "OK"
        except Exception as exc:  # noqa: BLE001 - envelope parity
            return f"IO_ERROR: {exc}"

    def transact(self, request: Dict[str, Any], timeout_s: float = 5.0) -> Dict[str, Any]:
        """Send request dict, return {'status': 'OK', 'value': msg} or failure envelope."""
        if not self.connected:
            return {"status": "NOT_CONNECTED"}
        try:
            self._port.write(encode_message(request))
        except Exception as exc:  # noqa: BLE001
            return {"status": "IO_ERROR", "error": str(exc)}
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            waiting = self._port.in_waiting
            if waiting:
                chunk = self._port.read(waiting)
                self._decoder.push(chunk)
            while self._decoder.frames:
                payload = self._decoder.frames.pop(0)
                try:
                    msg = decode_message(payload)
                except ProtocolError as exc:
                    return {"status": "BAD_FRAME", "error": str(exc)}
                if msg.type not in RESPONSE_TYPES:
                    continue  # ignore host-directed types on the response stream
                return {"status": "OK", "value": msg}
            time.sleep(0.005)
        return {"status": "TIMEOUT"}


class LoopbackTransport:
    """In-memory device stub — a hand-written real interface implementation,
    not a mock of owned code. Speaks the same wire bytes as real hardware:
    encode_message -> device stub decodes, replies, host decodes.
    """

    def __init__(self, device=None):
        self._decoder = FrameDecoder()
        self.device = device

    def transact(self, request: Dict[str, Any], timeout_s: float = 5.0) -> Dict[str, Any]:
        frame = encode_message(request)
        payload = decode_any_frame(frame)
        if self.device is None:
            return {"status": "OK", "value": DeviceError(code="INTERNAL", message="no device")}
        reply = self.device.handle(payload)
        if reply is None:
            return {"status": "TIMEOUT"}
        if isinstance(reply, (bytes, bytearray)) and reply and reply[0] in RESPONSE_TYPES:
            reply = decode_message(bytes(reply))
        return {"status": "OK", "value": reply}


def decode_any_frame(frame: bytes) -> bytes:
    """Decode a single stuffed frame back to its payload (host side of loopback)."""
    decoder = FrameDecoder()
    decoder.push(frame)
    if not decoder.frames:
        raise ProtocolError("frame did not decode")
    return decoder.frames[0]
