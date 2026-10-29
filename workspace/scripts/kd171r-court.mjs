#!/usr/bin/env node
// KD-171R off-host witness court for the /api/sync/state caller gate.
//
// Closes KD-171's close condition: "shared-secret/HMAC caller gate + witness
// court (unauthed non-loopback POST -> 403 witnessed from off-host, not just
// a header probe)".
//
// Two REAL Next dev servers, zero mocks:
//   Boot A (--secret):  SMALT_BFF_SYNC_SECRET set. Legs:
//     A1 off-host POST (to the machine's real non-loopback LAN IP, so the
//        Host header is genuinely non-loopback — not a spoofed header) with
//        no secret        -> 403 sync_state_non_loopback
//     A2 loopback, missing secret      -> 403 sync_state_missing_secret
//     A3 loopback, wrong secret        -> 403 sync_state_invalid_secret
//     A4 loopback, correct secret      -> route PROCEEDS (200 applied via the
//                                          real substrate cosmos face)
//   Boot B (posture):   SMALT_BFF_SYNC_SECRET unset. Legs:
//     B1 loopback, no secret header    -> PROCEEDS (KD-171 dev posture kept)
//     B2 loopback, header present      -> PROCEEDS (header inert when env unset)
//
// Exit 0 pass / 1 fail / 2 substrate never up / 3 harness-skip (loud).
import { spawn } from "node:child_process";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";

const WS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SECRET = "kd171r-court-secret-0f3a9";
const R = [];
function ok(name, cond, detail) {
  R.push(cond);
  console.log(`[${cond ? "PASS" : "FAIL"}] ${name} :: ${detail}`);
}

function lanIp() {
  for (const list of Object.values(os.networkInterfaces())) {
    for (const ni of list ?? []) {
      if (ni.family === "IPv4" && !ni.internal) return ni.address;
    }
  }
  return null;
}

function portFree(port) {
  return new Promise((resolve) => {
    const s = net.connect(port, "127.0.0.1");
    s.on("connect", () => { s.destroy(); resolve(false); });
    s.on("error", () => resolve(true));
  });
}

async function waitUp(url, deadlineMs, label) {
  const t0 = Date.now();
  while (Date.now() - t0 < deadlineMs) {
    try {
      const res = await fetch(url);
      if (res.status < 500) return true;
    } catch {}
    await sleep(500);
  }
  throw new Error(`${label} never came up at ${url}`);
}

function bootServer(port, env) {
  const child = spawn("npm", ["run", "dev", "--", "-H", "0.0.0.0", "-p", String(port)], {
    cwd: WS,
    env: { ...process.env, ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.on("data", () => {});
  child.stderr.on("data", () => {});
  return child;
}

function post(base, headers, body) {
  return fetch(new URL("/api/sync/state", base), {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

async function main() {
  const ip = lanIp();
  if (ip === null) {
    console.log("[SKIP] no non-loopback IPv4 interface — off-host leg impossible");
    process.exit(3);
  }

  // substrate data plane must be up for the proceed legs to be meaningful
  const SUB_URL = "http://127.0.0.1:8443/dbs";
  const subUp = await (async () => {
    try { const r = await fetch(SUB_URL); return r.status >= 400 && r.status < 500; }
    catch { return false; }
  })();
  if (!subUp) {
    console.log("[SKIP] substrate data plane :8443 down — run scripts/substrate.sh");
    process.exit(2);
  }

  const bootA = 18471 + (process.pid % 40);
  let bootB = bootA + 1;
  for (let i = 0; i < 20 && !(await portFree(bootB)); i++) bootB += 1;
  const procs = [];
  try {
    // ---- Boot A: secret mode ----
    procs.push(bootServer(bootA, { SMALT_BFF_SYNC_SECRET: SECRET }));
    const baseA = `http://127.0.0.1:${bootA}`;
    await waitUp(`${baseA}/api/sync/state`, 90_000, "boot A");

    // A1: off-host (real non-loopback destination IP -> real non-loopback Host)
    const r1 = await post(`http://${ip}:${bootA}`, {}, [{ id: "kd171r-a1", data: { v: 1 } }]);
    const j1 = await r1.json().catch(() => ({}));
    ok("A1 off-host no-secret -> 403 non_loopback",
      r1.status === 403 && j1.error === "sync_state_non_loopback",
      `status=${r1.status} body=${JSON.stringify(j1)}`);

    // A2: loopback, missing secret
    const r2 = await post(baseA, {}, [{ id: "kd171r-a2", data: { v: 1 } }]);
    const j2 = await r2.json().catch(() => ({}));
    ok("A2 loopback missing secret -> 403 missing_secret",
      r2.status === 403 && j2.error === "sync_state_missing_secret",
      `status=${r2.status} body=${JSON.stringify(j2)}`);

    // A3: loopback, wrong secret
    const r3 = await post(baseA, { "x-smalt-sync-secret": "wrong-secret" },
      [{ id: "kd171r-a3", data: { v: 1 } }]);
    const j3 = await r3.json().catch(() => ({}));
    ok("A3 loopback wrong secret -> 403 invalid_secret",
      r3.status === 403 && j3.error === "sync_state_invalid_secret",
      `status=${r3.status} body=${JSON.stringify(j3)}`);

    // A4: loopback, correct secret -> route proceeds to the real substrate
    const id4 = `kd171r-ok-${Date.now()}`;
    const r4 = await post(baseA, { "x-smalt-sync-secret": SECRET },
      [{ id: id4, data: { v: 1, note: "kd171r correct-secret apply" } }]);
    const j4 = await r4.json().catch(() => ({}));
    ok("A4 loopback correct secret -> route proceeds (applied)",
      r4.status === 200 && Array.isArray(j4.applied) && j4.applied.some((a) => a.id === id4),
      `status=${r4.status} body=${JSON.stringify(j4)}`);

    // ---- Boot B: posture mode (env unset) ----
    // Sequential: two concurrent `next dev` in one workspace contend on the
    // turbopack .next lock (witnessed: boot B never came up when spawned
    // alongside boot A). Boot A is done, kill it before boot B.
    procs[0].kill("SIGTERM");
    procs.shift();
    procs.push(bootServer(bootB, { SMALT_BFF_SYNC_SECRET: "" }));
    const baseB = `http://127.0.0.1:${bootB}`;
    await waitUp(`${baseB}/api/sync/state`, 90_000, "boot B");

    const idB1 = `kd171r-b1-${Date.now()}`;
    const rB1 = await post(baseB, {}, [{ id: idB1, data: { v: 1 } }]);
    const jB1 = await rB1.json().catch(() => ({}));
    ok("B1 env unset loopback no-secret -> proceeds",
      rB1.status === 200 && (jB1.applied ?? []).some((a) => a.id === idB1),
      `status=${rB1.status} body=${JSON.stringify(jB1)}`);

    const idB2 = `kd171r-b2-${Date.now()}`;
    const rB2 = await post(baseB, { "x-smalt-sync-secret": "ignored" },
      [{ id: idB2, data: { v: 1 } }]);
    const jB2 = await rB2.json().catch(() => ({}));
    ok("B2 env unset header-present -> proceeds (header inert)",
      rB2.status === 200 && (jB2.applied ?? []).some((a) => a.id === idB2),
      `status=${rB2.status} body=${JSON.stringify(jB2)}`);
  } finally {
    for (const p of procs) p.kill("SIGTERM");
  }

  const fails = R.filter((x) => !x).length;
  console.log(`\n# kd171r-court: ${R.length - fails}/${R.length} PASS, ${fails} FAIL`);
  if (fails > 0) {
    process.exit(1);
  }
  console.log("# VERDICT: PASS — KD-171 close condition witnessed");
}

main().catch((err) => {
  console.error(`# kd171r-court ERROR: ${err}`);
  process.exit(1);
});
