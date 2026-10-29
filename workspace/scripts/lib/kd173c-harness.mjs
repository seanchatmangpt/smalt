/**
 * KD-173C court harness — boots the workspace Next dev server (source truth,
 * no prebuilt .next dependency) on a loopback lane port with a given env
 * overlay, waits on the REAL observable (bounded poll on HTTP readiness, no
 * sleeps), and returns an async kill() for the caller's finally block.
 *
 * Same boot idiom as scripts/bench/lifecycle_harness.mjs (next server in the
 * workspace root, lane port). Ports 39751 (non-dev) / 39752 (dev plane).
 */

import { spawn } from 'node:child_process';
import path from 'node:path';
import { assertLocalUrl } from './airgap.mjs';

export async function nextDev(wsRoot, port, envOverlay) {
  const child = spawn(
    process.execPath,
    [path.join(wsRoot, 'node_modules/next/dist/bin/next'), 'dev', '-p', String(port), '-H', '127.0.0.1'],
    { cwd: wsRoot, env: { ...process.env, ...envOverlay }, stdio: ['ignore', 'pipe', 'pipe'], detached: true },
  );
  let log = '';
  const onLog = (c) => { log += c; };
  child.stdout.on('data', onLog);
  child.stderr.on('data', onLog);

  // Bounded poll on the real observable: any HTTP answer == server up.
  const deadline = Date.now() + 180_000;
  for (;;) {
    if (child.exitCode !== null) {
      throw new Error(`next dev :${port} exited ${child.exitCode}; log tail: ${log.slice(-1200)}`);
    }
    try {
      const u = assertLocalUrl(`http://127.0.0.1:${port}/api/v1/ingest`);
      await fetch(u, { signal: AbortSignal.timeout(2000) });
      break;
    } catch {
      if (Date.now() > deadline) {
        try { process.kill(-child.pid, 'SIGKILL'); } catch { /* already gone */ }
        throw new Error(`next dev :${port} not ready in 180s; log tail: ${log.slice(-1200)}`);
      }
      await new Promise((r) => setImmediate(r));
    }
  }

  const kill = async () => {
    // Tree kill: `next dev` traps SIGTERM (graceful, children keep writing
    // briefly), so SIGKILL-escalate the process group, then bounded-wait exit.
    try { process.kill(-child.pid, 'SIGTERM'); } catch { /* already gone */ }
    const t0 = Date.now();
    while (child.exitCode === null && Date.now() - t0 < 5_000) {
      await new Promise((r) => setImmediate(r));
    }
    try { process.kill(-child.pid, 'SIGKILL'); } catch { /* already gone */ }
    const deadline = Date.now() + 15_000;
    while (child.exitCode === null && Date.now() < deadline) {
      await new Promise((r) => setImmediate(r));
    }
  };
  kill.child = child;
  return kill;
}
