# WS-06 Receipt — Web Serial Hardware Gateway

- **Date**: 2026-10-15
- **Lane**: WS-6
- **Subject**: `/Users/sac/smalt/workspace/lib/serial/` (exact files below)
- **Base**: smalt main @ 3fc2543 (session start)

## Files (all absolute, all session-created)

- `/Users/sac/smalt/workspace/lib/serial/gateway.ts` — SerialGateway, frame codec,
  CRC-16/CCITT-FALSE + `crc16SelfTest()`.
- `/Users/sac/smalt/workspace/lib/serial/protocol.ts` — typed messages,
  `GatewayEnvelope<T>`, wire discriminators.
- `/Users/sac/smalt/workspace/lib/serial/gateway-events.ts` — `GatewayEvents` hooks.
- `/Users/sac/smalt/workspace/lib/serial/README.md` — wire contract.

## Verification (executed this session)

1. `tsc --noEmit --strict` (tsc 6.0.3):
   `npx --no-install tsc --noEmit --ignoreConfig --strict --target es2020 --module esnext --moduleResolution bundler --lib es2020,dom lib/serial/gateway.ts lib/serial/protocol.ts lib/serial/gateway-events.ts`
   → exit 0, `TSC_OK`.
2. Node self-test (compiled to temp CJS, executed, temp dir removed):
   - CRC-16/CCITT-FALSE("123456789") = 0x29B1 → PASS
   - frame round-trip x2 → PASS (40-byte SIGN_CHALLENGE frame)
   - byte-stuffing round-trip (payload with 0x7E/0x7D) → PASS
   - corrupted-CRC frame rejected by FrameDecoder → PASS
   - Node import (no `navigator.serial`) → `isSerialSupported()` false,
     `enroll()` returns `{status:"UNSUPPORTED", error:"Web Serial API unavailable in this runtime"}`
     — never throws → PASS

## Degradation

`navigator.serial` undefined (Node/SSR/Firefox/Safari) → all operations return
`GatewayEnvelope{status:"UNSUPPORTED"}`; no top-level window access; import-safe.

## Standing

ALIVE for codec + degradation paths (executed). Device-side SIGNED_RECEIPT /
CAPABILITIES payload layouts are UNVERIFIED against real hardware (no device in
this session); layouts specified in README.md for device-firmware alignment.
