// poll.ts — the ONLY wait primitive in the TS verification tier.
// boundedPoll: deadline-checked polling of a real observable, exponential
// backoff 10ms→200ms cap. Fixed sleeps are banned in workflow code; waits
// derived from observed Retry-After headers are lawful scheduling.
export interface PollOpts {
  timeoutMs: number;
  intervalMs?: number;
  label: string;
}

export async function boundedPoll<T>(
  label: string,
  probe: () => Promise<T | null> | T,
  timeoutMs: number,
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  let interval = 10;
  for (;;) {
    const result = await probe();
    if (result !== null && result !== undefined) return result;
    if (Date.now() >= deadline) {
      throw new PollTimeout(label, timeoutMs);
    }
    await sleep(Math.min(interval, Math.max(0, deadline - Date.now())));
    interval = Math.min(interval * 2, 200);
  }
}

export class PollTimeout extends Error {
  constructor(label: string, timeoutMs: number) {
    super(`POLL-TIMEOUT: ${label} not observed within ${timeoutMs}ms`);
    this.name = "PollTimeout";
  }
}

export function sleep(ms: number): Promise<void> {
  // SLEEP-CLASS: POLL-STEP — the backoff step inside boundedPoll; every wait
  // is deadline-checked against the polled observable, never a fixed sleep.
  return new Promise((r) => setTimeout(r, ms));
}
