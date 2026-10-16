/**
 * Event hooks for the Web Serial gateway. Plain callback interface — no
 * Node EventEmitter dependency so it stays SSR/browser-safe.
 */

import type { ResponseMessage } from './protocol';

export interface PortInfo {
  usbVendorId?: number;
  usbProductId?: number;
}

export interface GatewayEvents {
  /** Port opened at 115200 8N1. */
  onConnect?(info: PortInfo): void;
  /** Port closed or lost. */
  onDisconnect?(): void;
  /** Any device->host message after decode (including ERROR frames). */
  onMessage?(message: ResponseMessage): void;
  /** Read-loop or decode failures; envelope status still carries the type. */
  onError?(message: string): void;
}
