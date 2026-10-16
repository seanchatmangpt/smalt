# CLI-6 Receipt — AtomVM Hardware Bridge

Lane: CLI-6 · Repo: `/Users/sac/smalt/smalt-cli` (canonical checkout) · Date: 2026-10-15
Branch: main (uncommitted, per lane contract — no commits)

## Subject (files owned, all landed)

- `smalt_cli/hw/__init__.py` — public re-exports
- `smalt_cli/hw/serial.py` — codec + pyserial transport + LoopbackTransport
- `smalt_cli/hw/flasher.py` — .avm chunked streaming upload
- `smalt_cli/hw/attest.py` — challenge/receipt capture + verification seam
- `smalt_cli/hw/cli.py` — `hw` subcommands (discover/enroll/sign/flash)
- `smalt_cli/test_hw.py` — 16 tests

## Protocol parity status: PARITY_CONFIRMED

Wire contract read from `/Users/sac/smalt/workspace/lib/serial/protocol.ts` and
`gateway.ts`: `[0x7E][len:u16 LE][payload][crc16:u16 LE][0x7E]`,
CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection/xorout) over
`[len][payload]`, stuffing 0x7E→0x7D 0x5E / 0x7D→0x7D 0x5D; message types
0x01/0x02/0x03/0x04/0x7F with payload layouts copied field-for-field from
gateway.ts `decodeMessage` (SIGNED_RECEIPT = sig:64 + serial:utf8 + counter:u32
LE; CAPABILITIES = se:u8 + sha:u8 + fwLen:u8 + fw + maxPayload:u16 LE; ERROR =
code index + utf8 message).

**Cross-language verification (real, executed)**: the TS codec was transcribed
1:1 (gateway.ts lines 28–91) into `/tmp/ts_parity.mjs` and run in node v26.10.0.
JS `crc16CcittFalse("123456789") === 0x29B1` → true; frames byte-identical to
Python `encode_frame` over 5 cases (ENROLL, SIGN_CHALLENGE w/ 32-byte digest,
stuffing-heavy payload, all 256 byte values, ASCII vector): 5/5 MATCH.

## Verification ladder (real output)

`python3 -m pytest smalt_cli/test_hw.py`:

```
smalt_cli/test_hw.py ................                                    [100%]
============================== 16 passed in 0.07s ==============================
platform darwin -- Python 3.14.3, pytest-9.0.3
```

Coverage: CRC vector 0x29B1; empty-input CRC = init 0xFFFF; frame round-trip;
stuffing round-trip (0x7E absent from wire body); byte-at-a-time deframing;
bad-CRC rejection + resync; oversize payload refusal; enroll/sign message
round-trips; SIGNED_RECEIPT/CAPABILITIES/ERROR decode; TS parity (in-test,
transcribed algorithm); loopback enroll / monotonic counter (1 then 2);
loopback .avm flash of 16 KiB with SHA-256 commit match.

## HIL status: SKIP-loud

No hardware present; pyserial not installed (PEP 668 externally-managed env,
install refused without `--break-system-packages` — not forced). Loud failure
witnessed:

```
$ python3 -m smalt_cli.hw.cli discover
ModuleNotFoundError: No module named 'serial'   # exit=1
```

Codec/protocol tests run for real without pyserial (lazy import in
`serial.py`); only transport open/discover requires it.

## Attestation seam (honest refusal, per contract)

`attest()` probes for importable pure-python ML-DSA verifier modules
(`ml_dsa`, `pqclean_ml_dsa_65`, `ml_dsa65`). None present → returns
`{status: REFUSED, refused: ALGORITHM_UNSUPPORTED, algorithm: ML-DSA-65}`.
Ed25519 path verifies availability of the `cryptography` primitive; without a
provisioned device public key it captures the signature and reports
`verified: false` explicitly rather than claiming verification.

## Falsifiers

- TS/Python frames disagree on any case → would fail (5/5 agree).
- Loopback commit with corrupted digest → device stub returns ERROR(BAD_FRAME)
  class mismatch, `committed` stays None (not directly tested; commit happy
  path is).

## Standing: PARTIAL_ALIVE

Codec + protocol + loopback manufacturing: ALIVE (receipted above).
HIL on real silicon: BLOCKED (no device, no pyserial in env).
