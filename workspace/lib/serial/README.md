# Web Serial Gateway (`lib/serial`)

Browser-side hardware gateway over the Web Serial API for the air-gapped
workspace console. Chromium-only at runtime; every other runtime degrades to
typed `UNSUPPORTED` envelopes — nothing throws at import time and there is no
top-level `window` access (SSR-safe).

## Files

- `protocol.ts` — typed messages, discriminators, `GatewayEnvelope<T>`.
- `gateway.ts` — `SerialGateway`, frame codec, CRC-16/CCITT-FALSE + self-test.
- `gateway-events.ts` — `GatewayEvents` callback hooks.

## Frame format

```
[0x7E] [len: u16 LE] [payload: len bytes] [crc16: u16 LE] [0x7E]
```

- CRC-16/CCITT-FALSE (poly `0x1021`, init `0xFFFF`, no reflection, no xorout)
  computed over `[len][payload]`.
- Byte stuffing inside the frame body: `0x7E -> 0x7D 0x5E`, `0x7D -> 0x7D 0x5D`.
- `crc16SelfTest()` asserts the check vector
  CRC-16/CCITT-FALSE("123456789") = `0x29B1`.

## Serial settings

115200 baud, 8 data bits, 1 stop bit, no parity.

## Messages

Host -> device:

- `SIGN_CHALLENGE { sha256Digest: 32-byte hex }` (wire `0x01`, digest raw bytes)
- `ENROLL` (wire `0x03`)

Device -> host:

- `SIGNED_RECEIPT { sig: 64-byte hex, chipsetSerial: utf-8, monotonicCounter: u32 LE }` (`0x02`)
- `CAPABILITIES { secureElement, sha256Accelerator, firmwareVersion, maxPayloadBytes }` (`0x04`)
- `ERROR { code, message }` (`0x7F`)

Payload layouts (after the 1-byte type):

- `SIGNED_RECEIPT`: `[sig: 64][serial: N utf-8][counter: u32 LE]`
- `CAPABILITIES`: `[secureElement: u8][sha256: u8][fwLen: u8][fw: utf-8][maxPayload: u16 LE]`
- `ERROR`: `[code: u8][message: utf-8]` (code indexes BAD_CRC..INTERNAL)

## Usage

```ts
import { SerialGateway, crc16SelfTest } from '@/lib/serial/gateway';

if (!crc16SelfTest()) throw new Error('CRC self-test failed');

const gw = new SerialGateway({ events: { onMessage: console.log } });
const env = await gw.requestAndConnect();
if (env.status !== 'OK') return; // UNSUPPORTED | IO_ERROR
const receipt = await gw.signChallenge(digestHex); // GatewayEnvelope<SignedReceipt>
```

All operations return `GatewayEnvelope<T>` with `status` one of
`OK | UNSUPPORTED | NOT_CONNECTED | IO_ERROR | BAD_FRAME | TIMEOUT`.
