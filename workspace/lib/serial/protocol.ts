/**
 * Web Serial gateway wire protocol — typed messages.
 *
 * Transport framing (codec in gateway.ts):
 *   [0x7E] [len:u16 LE] [payload...] [crc16:u16 LE] [0x7E]
 * with byte-stuffing: 0x7E -> 0x7D 0x5E, 0x7D -> 0x7D 0x5D.
 * CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) over [len][payload].
 */

/** Message type discriminators on the wire. */
export const MsgType = {
  SIGN_CHALLENGE: 0x01,
  SIGNED_RECEIPT: 0x02,
  ENROLL: 0x03,
  CAPABILITIES: 0x04,
  ERROR: 0x7f,
} as const;

export type MsgType = (typeof MsgType)[keyof typeof MsgType];

/** Host -> device: request signature over a sha256 digest (hex, 64 chars). */
export interface SignChallenge {
  type: typeof MsgType.SIGN_CHALLENGE;
  /** hex-encoded SHA-256 digest (64 chars). */
  sha256Digest: string;
}

/** Device -> host: proof-of-possession receipt. */
export interface SignedReceipt {
  type: typeof MsgType.SIGNED_RECEIPT;
  /** hex-encoded device signature over the digest. */
  sig: string;
  /** stable chipset identity reported by the secure element. */
  chipsetSerial: string;
  /** device monotonic counter, strictly increasing per signature. */
  monotonicCounter: number;
}

/** Host -> device: begin enrollment. */
export interface Enroll {
  type: typeof MsgType.ENROLL;
}

/** Device -> host: post-enrollment capability report. */
export interface Capabilities {
  type: typeof MsgType.CAPABILITIES;
  /** secure element present and healthy. */
  secureElement: boolean;
  /** hardware SHA-256 acceleration available. */
  sha256Accelerator: boolean;
  /** firmware version string. */
  firmwareVersion: string;
  /** maximum payload bytes the device will accept per frame. */
  maxPayloadBytes: number;
}

/** Device -> host: typed failure. */
export interface ProtocolError {
  type: typeof MsgType.ERROR;
  code:
    | 'BAD_CRC'
    | 'BAD_FRAME'
    | 'UNKNOWN_TYPE'
    | 'NOT_ENROLLED'
    | 'BAD_DIGEST'
    | 'INTERNAL';
  message: string;
}

export type RequestMessage = SignChallenge | Enroll;
export type ResponseMessage = SignedReceipt | Capabilities | ProtocolError;
export type ProtocolMessage = RequestMessage | ResponseMessage;

/** Envelope every gateway operation returns — never throws across the boundary. */
export type GatewayStatus =
  | 'OK'
  | 'UNSUPPORTED'
  | 'NOT_CONNECTED'
  | 'IO_ERROR'
  | 'BAD_FRAME'
  | 'TIMEOUT';

export interface GatewayEnvelope<T> {
  status: GatewayStatus;
  value?: T;
  error?: string;
}

export function isResponseMessage(m: ProtocolMessage): m is ResponseMessage {
  return (
    m.type === MsgType.SIGNED_RECEIPT ||
    m.type === MsgType.CAPABILITIES ||
    m.type === MsgType.ERROR
  );
}
