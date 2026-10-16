/**
 * Web Serial API gateway — requestPort/connect at 115200 8N1, frame codec
 * ([0x7E][len:u16 LE][payload][crc16:u16 LE][0x7E], byte-stuffing 0x7D escape,
 * CRC-16/CCITT-FALSE), typed request/response exchange.
 *
 * SSR-safe: no window/navigator access at module top level; all Web Serial
 * references are behind runtime feature detection. When navigator.serial is
 * undefined the gateway returns UNSUPPORTED envelopes — it never throws.
 */

import {
  MsgType,
  type Capabilities,
  type Enroll,
  type GatewayEnvelope,
  type ProtocolError,
  type RequestMessage,
  type ResponseMessage,
  type SignChallenge,
  type SignedReceipt,
} from './protocol';
import type { GatewayEvents } from './gateway-events';

// ---------------------------------------------------------------------------
// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, no xorout)
// ---------------------------------------------------------------------------

export function crc16CcittFalse(data: Uint8Array): number {
  let crc = 0xffff;
  for (let i = 0; i < data.length; i++) {
    crc ^= data[i] << 8;
    for (let b = 0; b < 8; b++) {
      crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
    }
  }
  return crc;
}

/**
 * Witnessed self-test: CRC-16/CCITT-FALSE("123456789") must equal 0x29B1.
 * Throws only if called and the implementation is wrong — call once in dev.
 * @returns true when the implementation matches the check value.
 */
export function crc16SelfTest(): boolean {
  const bytes = new TextEncoder().encode('123456789');
  return crc16CcittFalse(bytes) === 0x29b1;
}

// ---------------------------------------------------------------------------
// Frame codec
// ---------------------------------------------------------------------------

const FLAG = 0x7e;
const ESC = 0x7d;
const ESC_XOR = 0x20;

export const MAX_PAYLOAD_BYTES = 4096;

function stuff(payload: Uint8Array): Uint8Array {
  const out: number[] = [];
  for (const b of payload) {
    if (b === FLAG || b === ESC) {
      out.push(ESC, b ^ ESC_XOR);
    } else {
      out.push(b);
    }
  }
  return Uint8Array.from(out);
}

/** Encode one frame: [0x7E][len LE][payload][crc LE][0x7E], stuffed. */
export function encodeFrame(payload: Uint8Array): Uint8Array {
  if (payload.length > MAX_PAYLOAD_BYTES) {
    throw new RangeError(`payload ${payload.length} > ${MAX_PAYLOAD_BYTES}`);
  }
  const len = new Uint8Array([payload.length & 0xff, (payload.length >> 8) & 0xff]);
  const body = new Uint8Array(len.length + payload.length);
  body.set(len, 0);
  body.set(payload, len.length);
  const crc = crc16CcittFalse(body);
  const tail = new Uint8Array(body.length + 2);
  tail.set(body, 0);
  tail[body.length] = crc & 0xff;
  tail[body.length + 1] = (crc >> 8) & 0xff;
  const stuffed = stuff(tail);
  const frame = new Uint8Array(stuffed.length + 2);
  frame[0] = FLAG;
  frame.set(stuffed, 1);
  frame[frame.length - 1] = FLAG;
  return frame;
}

/**
 * Streaming deframer. Feed raw bytes; completed payloads are drained from
 * `frames`. Resynchronizes on the next 0x7E after any malformed frame.
 */
export class FrameDecoder {
  private buf: number[] = [];
  private inFrame = false;
  private escaped = false;
  readonly frames: Uint8Array[] = [];

  push(chunk: Uint8Array): void {
    for (let i = 0; i < chunk.length; i++) {
      const b = chunk[i];
      if (b === FLAG) {
        if (this.inFrame && this.buf.length > 0) this.tryEmit();
        this.inFrame = true;
        this.buf = [];
        this.escaped = false;
        continue;
      }
      if (!this.inFrame) continue; // noise between flags
      if (b === ESC) {
        this.escaped = true;
        continue;
      }
      if (this.escaped) {
        this.buf.push(b ^ ESC_XOR);
        this.escaped = false;
      } else {
        this.buf.push(b);
      }
    }
  }

  private tryEmit(): void {
    const raw = Uint8Array.from(this.buf);
    this.buf = [];
    this.escaped = false;
    if (raw.length < 4) return; // need len(2)+crc(2)
    const len = raw[0] | (raw[1] << 8);
    const expected = 2 + len + 2;
    if (raw.length !== expected) return;
    const body = raw.subarray(0, raw.length - 2);
    const crc = raw[raw.length - 2] | (raw[raw.length - 1] << 8);
    if (crc16CcittFalse(body) !== crc) return;
    this.frames.push(raw.subarray(2, 2 + len));
  }
}

// ---------------------------------------------------------------------------
// Web Serial feature detection (SSR-safe)
// ---------------------------------------------------------------------------

interface MinimalSerialPort {
  open(options: {
    baudRate: number;
    dataBits?: number;
    stopBits?: number;
    parity?: 'none' | 'even' | 'odd';
  }): Promise<void>;
  close(): Promise<void>;
  readonly readable: ReadableStream<Uint8Array> | null;
  readonly writable: WritableStream<Uint8Array> | null;
  getInfo(): { usbVendorId?: number; usbProductId?: number };
}

interface MinimalSerial {
  requestPort(options?: { filters?: Array<{ usbVendorId?: number; usbProductId?: number }> }): Promise<MinimalSerialPort>;
  getPorts(): Promise<MinimalSerialPort[]>;
}

function getSerial(): MinimalSerial | null {
  if (typeof navigator === 'undefined') return null;
  const nav = navigator as unknown as { serial?: MinimalSerial };
  return nav.serial ?? null;
}

export function isSerialSupported(): boolean {
  return getSerial() !== null;
}

// ---------------------------------------------------------------------------
// Gateway
// ---------------------------------------------------------------------------

export interface SerialGatewayOptions {
  baudRate?: number;
  /** per-request timeout in ms (default 5000). */
  timeoutMs?: number;
  events?: GatewayEvents;
}

const DEFAULT_BAUD = 115200;

export class SerialGateway {
  private port: MinimalSerialPort | null = null;
  private reader: ReadableStreamDefaultReader<Uint8Array> | null = null;
  private decoder = new FrameDecoder();
  private pendingResolvers: Array<(m: ResponseMessage) => void> = [];
  private readLoopRunning = false;
  private readonly baudRate: number;
  private readonly timeoutMs: number;
  private readonly events?: GatewayEvents;

  constructor(options: SerialGatewayOptions = {}) {
    this.baudRate = options.baudRate ?? DEFAULT_BAUD;
    this.timeoutMs = options.timeoutMs ?? 5000;
    this.events = options.events;
  }

  /** Prompt the user to pick a device and open it at 115200 8N1. */
  async requestAndConnect(): Promise<GatewayEnvelope<{ opened: true }>> {
    const serial = getSerial();
    if (!serial) {
      return { status: 'UNSUPPORTED', error: 'Web Serial API unavailable in this runtime' };
    }
    try {
      this.port = await serial.requestPort();
      await this.port.open({
        baudRate: this.baudRate,
        dataBits: 8,
        stopBits: 1,
        parity: 'none',
      });
      this.startReadLoop();
      this.events?.onConnect?.(this.port.getInfo());
      return { status: 'OK', value: { opened: true } };
    } catch (e) {
      this.port = null;
      return { status: 'IO_ERROR', error: describe(e) };
    }
  }

  async disconnect(): Promise<GatewayEnvelope<{ closed: true }>> {
    if (!this.port) return { status: 'NOT_CONNECTED' };
    try {
      this.readLoopRunning = false;
      try {
        await this.reader?.cancel();
      } catch {
        /* port already gone */
      }
      this.reader = null;
      await this.port.close();
      this.port = null;
      this.events?.onDisconnect?.();
      return { status: 'OK', value: { closed: true } };
    } catch (e) {
      return { status: 'IO_ERROR', error: describe(e) };
    }
  }

  get connected(): boolean {
    return this.port !== null;
  }

  /** Send a request and await the next matching device response. */
  async transact(request: RequestMessage): Promise<GatewayEnvelope<ResponseMessage>> {
    if (!this.port) {
      return isSerialSupported()
        ? { status: 'NOT_CONNECTED' }
        : { status: 'UNSUPPORTED', error: 'Web Serial API unavailable in this runtime' };
    }
    const encoded = encodeMessage(request);
    try {
      const writer = this.port.writable!.getWriter();
      try {
        await writer.write(encoded);
      } finally {
        writer.releaseLock();
      }
    } catch (e) {
      return { status: 'IO_ERROR', error: describe(e) };
    }
    return this.awaitResponse();
  }

  private awaitResponse(): Promise<GatewayEnvelope<ResponseMessage>> {
    return new Promise((resolve) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        this.pendingResolvers = this.pendingResolvers.filter((r) => r !== onMessage);
        resolve({ status: 'TIMEOUT' });
      }, this.timeoutMs);
      const onMessage = (m: ResponseMessage) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve({ status: 'OK', value: m });
      };
      this.pendingResolvers.push(onMessage);
    });
  }

  // -- typed operations -----------------------------------------------------

  signChallenge(digestHex: string): Promise<GatewayEnvelope<SignedReceipt>> {
    return this.transact({ type: MsgType.SIGN_CHALLENGE, sha256Digest: digestHex }).then(
      (env) => unwrapAs<SignedReceipt>(env),
    );
  }

  enroll(): Promise<GatewayEnvelope<Capabilities>> {
    return this.transact({ type: MsgType.ENROLL }).then((env) =>
      unwrapAs<Capabilities>(env),
    );
  }

  // -- internals -------------------------------------------------------------

  private startReadLoop(): void {
    if (this.readLoopRunning || !this.port?.readable) return;
    this.readLoopRunning = true;
    void (async () => {
      while (this.readLoopRunning && this.port?.readable) {
        this.reader = this.port.readable.getReader();
        try {
          for (;;) {
            const { value, done } = await this.reader.read();
            if (done) break;
            this.decoder.push(value);
            this.drainFrames();
          }
        } catch (e) {
          this.events?.onError?.(describe(e));
        } finally {
          this.reader.releaseLock();
          this.reader = null;
        }
      }
      this.readLoopRunning = false;
    })();
  }

  private drainFrames(): void {
    while (this.decoder.frames.length > 0) {
      const payload = this.decoder.frames.shift()!;
      let msg: ResponseMessage;
      try {
        msg = decodeMessage(payload);
      } catch (e) {
        this.events?.onError?.(describe(e));
        continue;
      }
      if (!isResponseType(msg.type)) {
        this.events?.onError?.(`unexpected message type 0x${msg.type.toString(16)}`);
        continue;
      }
      this.events?.onMessage?.(msg);
      const resolver = this.pendingResolvers.shift();
      resolver?.(msg);
    }
  }
}

function isResponseType(t: number): boolean {
  return (
    t === MsgType.SIGNED_RECEIPT ||
    t === MsgType.CAPABILITIES ||
    t === MsgType.ERROR
  );
}

function unwrapAs<T extends ResponseMessage>(env: GatewayEnvelope<ResponseMessage>): GatewayEnvelope<T> {
  if (env.status === 'OK') return { status: 'OK', value: env.value as T };
  return { status: env.status, error: env.error };
}

// -- message <-> bytes -------------------------------------------------------

const enc = new TextEncoder();
const dec = new TextDecoder();

function hexToBytes(hex: string): Uint8Array {
  if (hex.length % 2 !== 0 || /[^0-9a-fA-F]/.test(hex)) {
    throw new TypeError('invalid hex string');
  }
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function encodeMessage(m: RequestMessage): Uint8Array {
  switch (m.type) {
    case MsgType.SIGN_CHALLENGE: {
      const digest = hexToBytes(m.sha256Digest);
      if (digest.length !== 32) throw new TypeError('sha256Digest must be 32 bytes');
      const payload = new Uint8Array(1 + digest.length);
      payload[0] = MsgType.SIGN_CHALLENGE;
      payload.set(digest, 1);
      return encodeFrame(payload);
    }
    case MsgType.ENROLL:
      return encodeFrame(Uint8Array.from([MsgType.ENROLL]));
  }
}

function decodeMessage(payload: Uint8Array): ResponseMessage {
  if (payload.length === 0) throw new TypeError('empty payload');
  const type = payload[0];
  const rest = payload.subarray(1);
  switch (type) {
    case MsgType.SIGNED_RECEIPT: {
      // [sig: 64 bytes][serial: N bytes utf-8][counter: u32 LE]
      if (rest.length < 64 + 1 + 4) throw new TypeError('SIGNED_RECEIPT truncated');
      const sig = bytesToHex(rest.subarray(0, 64));
      const counter =
        rest[rest.length - 1] |
        (rest[rest.length - 2] << 8) |
        (rest[rest.length - 3] << 16) |
        (rest[rest.length - 4] << 24);
      const serial = dec.decode(rest.subarray(64, rest.length - 4));
      const msg: SignedReceipt = {
        type,
        sig,
        chipsetSerial: serial,
        monotonicCounter: counter >>> 0,
      };
      return msg;
    }
    case MsgType.CAPABILITIES: {
      // [secureElement:u8][sha256:u8][fwLen:u8][fw:utf-8][maxPayload:u16 LE]
      if (rest.length < 5) throw new TypeError('CAPABILITIES truncated');
      const fwLen = rest[2];
      if (rest.length < 3 + fwLen + 2) throw new TypeError('CAPABILITIES truncated');
      const maxPayload = rest[3 + fwLen] | (rest[4 + fwLen] << 8);
      const msg: Capabilities = {
        type,
        secureElement: rest[0] !== 0,
        sha256Accelerator: rest[1] !== 0,
        firmwareVersion: dec.decode(rest.subarray(3, 3 + fwLen)),
        maxPayloadBytes: maxPayload,
      };
      return msg;
    }
    case MsgType.ERROR: {
      return {
        type,
        code: errorCodeFrom(rest[0] ?? 0),
        message: dec.decode(rest.subarray(1)),
      } satisfies ProtocolError;
    }
    default:
      throw new TypeError(`unknown message type 0x${type.toString(16)}`);
  }
}

function errorCodeFrom(b: number): ProtocolError['code'] {
  const codes: ProtocolError['code'][] = [
    'BAD_CRC',
    'BAD_FRAME',
    'UNKNOWN_TYPE',
    'NOT_ENROLLED',
    'BAD_DIGEST',
    'INTERNAL',
  ];
  return codes[b] ?? 'INTERNAL';
}

function bytesToHex(b: Uint8Array): string {
  let s = '';
  for (const x of b) s += x.toString(16).padStart(2, '0');
  return s;
}

function describe(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
