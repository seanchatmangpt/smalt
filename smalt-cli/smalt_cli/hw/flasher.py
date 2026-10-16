"""AtomVM packbeam (.avm) upload — chunked frame streaming over the hw codec.

Chunks the .avm image into MAX_PAYLOAD_BYTES-bounded data chunks and streams
them as SIGN_CHALLENGE-style framed payloads... no: uses a dedicated flash
chunk convention on the wire: each chunk payload is
  [0xA0 chunk-start][index:u32 LE][data:N bytes]
terminated by [0xA1 commit][total_len:u32 LE][sha256:32 bytes].
The device stub in test_hw.py implements the same convention.
"""

from __future__ import annotations

import hashlib
from typing import Any, Callable, Dict, Optional

from .serial import SerialTransport, LoopbackTransport

CHUNK_START = 0xA0
CHUNK_COMMIT = 0xA1

# PAYLOAD budget per chunk: 1 type + 4 index leaves room for data.
_CHUNK_DATA_MAX = 4096 - 5


def flash_avm(
    transport,
    avm_path: str,
    chunk_data_max: int = _CHUNK_DATA_MAX,
    progress: Optional[Callable[[int, int], None]] = None,
) -> Dict[str, Any]:
    """Stream a .avm packbeam image in chunked frames. Returns an envelope."""
    try:
        with open(avm_path, "rb") as fh:
            image = fh.read()
    except OSError as exc:
        return {"status": "IO_ERROR", "error": str(exc)}

    total = len(image)
    digest = hashlib.sha256(image).digest()
    index = 0
    for offset in range(0, total, chunk_data_max):
        chunk = image[offset : offset + chunk_data_max]
        payload = bytes([CHUNK_START]) + index.to_bytes(4, "little") + chunk
        env = _send_payload(transport, payload)
        if env["status"] != "OK":
            return env
        index += 1
        if progress is not None:
            progress(min(offset + len(chunk), total), total)

    commit = bytes([CHUNK_COMMIT]) + total.to_bytes(4, "little") + digest
    return _send_payload(transport, commit)


def _send_payload(transport, payload: bytes) -> Dict[str, Any]:
    # SerialTransport.transact takes a message dict; for raw flash payloads we
    # encode the frame directly and reuse the transport write path.
    from .serial import encode_frame, decode_message

    if isinstance(transport, SerialTransport):
        try:
            transport._port.write(encode_frame(payload))
        except Exception as exc:  # noqa: BLE001
            return {"status": "IO_ERROR", "error": str(exc)}
        import time

        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            waiting = transport._port.in_waiting
            if waiting:
                transport._decoder.push(transport._port.read(waiting))
            while transport._decoder.frames:
                try:
                    msg = decode_message(transport._decoder.frames.pop(0))
                except Exception as exc:  # noqa: BLE001
                    return {"status": "BAD_FRAME", "error": str(exc)}
                return {"status": "OK", "value": msg}
            time.sleep(0.005)
        return {"status": "TIMEOUT"}
    if isinstance(transport, LoopbackTransport):
        frame = encode_frame(payload)
        from .serial import FrameDecoder

        dec = FrameDecoder()
        dec.push(frame)
        reply = transport.device.handle(dec.frames[0])
        return {"status": "OK", "value": reply}
    return {"status": "UNSUPPORTED", "error": "unknown transport type"}
