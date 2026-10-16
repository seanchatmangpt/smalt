// store.ts — N-2 action-storm lane: AsyncLocalStorage request context.
// One ALS instance per server process; each action invocation runs inside
// als.run() with a fresh request-id so cross-request state pollution
// (session leak) is observable by echoing the id back on the response.
import { AsyncLocalStorage } from "node:async_hooks";

export type BenchRequestContext = {
  requestId: string;
  clientToken: string;
  startedAtMs: number;
};

export const benchAls = new AsyncLocalStorage<BenchRequestContext>();

const RID_ALPHABET = "0123456789abcdef";

export function mintRequestId(): string {
  let id = "n2-";
  for (let i = 0; i < 24; i++) {
    id += RID_ALPHABET[Math.floor(Math.random() * 16)];
  }
  return id;
}
