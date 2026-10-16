"""AtomVM hardware bridge for smalt-cli.

Wire protocol parity with workspace/lib/serial/{protocol,gateway}.ts:
[0x7E][len:u16 LE][payload][crc16:u16 LE][0x7E], CRC-16/CCITT-FALSE,
byte-stuffing 0x7E -> 0x7D 0x5E, 0x7D -> 0x7D 0x5D.
"""

from .serial import (
    MSG_CAPABILITIES,
    MSG_ENROLL,
    MSG_ERROR,
    MSG_SIGN_CHALLENGE,
    MSG_SIGNED_RECEIPT,
    MAX_PAYLOAD_BYTES,
    ERROR_CODES,
    crc16_ccitt_false,
    crc16_self_test,
    encode_frame,
    FrameDecoder,
    encode_message,
    decode_message,
)
from .serial import SerialTransport, LoopbackTransport

__all__ = [
    "MSG_SIGN_CHALLENGE",
    "MSG_SIGNED_RECEIPT",
    "MSG_ENROLL",
    "MSG_CAPABILITIES",
    "MSG_ERROR",
    "MAX_PAYLOAD_BYTES",
    "ERROR_CODES",
    "crc16_ccitt_false",
    "crc16_self_test",
    "encode_frame",
    "FrameDecoder",
    "encode_message",
    "decode_message",
    "SerialTransport",
]
