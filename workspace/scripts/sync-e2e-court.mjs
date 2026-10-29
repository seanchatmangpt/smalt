#!/usr/bin/env node
// BK-83 authenticated sync end-to-end court. Plain node, no new deps.
// Legs: tokenless 401 challenge, real STS mint, tokenless flushSync,
// 5 appends -> authenticated flushSync (320-byte receipt, verified:true),
// 2 appends + client-side frame corruption -> typed refusal + snapback,
// clean re-sync. Exit 0 pass / 1 fail / 2 substrate never up.
//
// EXPLORE-1 W2: every collaborator is tracked. The IndexedDB shim and the
// boot.exs witness runtime live in workspace/scripts/bk83/ (tracked); the
// node-compatible engine copies are GENERATED at court start from the tracked
// workspace/lib sources (single source of truth — no BK-73 stale-copy class)
// into an OS temp dir, with import specifiers rewritten to explicit `.ts`
// (node type-stripping requires extensions). A fresh clone runs this court.
import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(fileURLToPath(import.meta.url), "../../..");
const { installIdbShim } = await import(new URL("./bk83/idb-shim.mjs", import.meta.url).href);

// Generate node-runnable engine copies from the tracked lib sources: copy
// byte-for-byte and append `.ts` to relative import specifiers (the lib uses
// extensionless imports for the bundler; node type-stripping needs extensions).
function genEngineScratch() {
  const out = fs.mkdtempSync(path.join(os.tmpdir(), "bk83-engine-"));
  fs.mkdirSync(path.join(out, "engine"), { recursive: true });
  const files = [
    ["workspace/lib/engine/codec.ts", "engine/codec.ts"],
    ["workspace/lib/engine/journal-sync.ts", "engine/journal-sync.ts"],
    ["workspace/lib/engine/merkle.ts", "engine/merkle.ts"],
    ["workspace/lib/engine/receipt.ts", "engine/receipt.ts"],
    ["workspace/lib/engine/snapback.ts", "engine/snapback.ts"],
    ["workspace/lib/engine/tab-lease.ts", "engine/tab-lease.ts"],
    ["workspace/lib/smalt.ts", "smalt.ts"],
  ];
  for (const [srcRel, outRel] of files) {
    const src = fs.readFileSync(path.join(ROOT, srcRel), "utf8");
    const rewritten = src.replace(
      /from "((?:\.\/|\.\.\/)[a-z-]+)"/g,
      (_m, spec) => `from "${spec}.ts"`
    );
    fs.writeFileSync(path.join(out, outRel), rewritten);
  }
  return out;
}

const BASE = "http://127.0.0.1:18543";
const STS = "http://127.0.0.1:18581";
const SYNC_URL = BASE + "/sync/journal/batch";
const CLIENT_ID = BigInt(0x636300 + (process.pid % 250));
const R = [];
function ok(name, cond, detail) {
  R.push(cond);
  const v = cond ? "PASS" : "FAIL";
  console.log(`[${v}] ${name} :: ${detail}`);
}

async function waitUp(url, deadlineMs) {
  const t0 = Date.now();
  while (Date.now() - t0 < deadlineMs) {
    try {
      await fetch(url);
      return true;
    } catch {}
    await sleep(500);
  }
  return false;
}

// BK-92-F1 harness determinism: a previous run's beam may still hold :18543
// when this run boots (SIGTERM is async). Booting into an occupied port makes
// the court talk to a STALE runtime with leftover per-client journal state
// (server head != 0 -> leg-4 refusal). Wait for both ports to be free first.
function portBusy(port) {
  return new Promise((resolve) => {
    const s = net.connect(port, "127.0.0.1");
    s.on("connect", () => {
      s.destroy();
      resolve(true);
    });
    s.on("error", () => resolve(false));
  });
}

async function waitPortFree(port, deadlineMs) {
  const t0 = Date.now();
  while (Date.now() - t0 < deadlineMs) {
    if (!(await portBusy(port))) return true;
    await sleep(500);
  }
  return false;
}

async function stsMint() {
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: "bk83-court",
    client_secret: "bk83-court-secret",
  });
  const url = STS + "/00000000-0000-0000-0000-000000000000/oauth2/v2.0/token";
  // Bounded poll on the real observable (a token mint): the boot marker can
  // print before the STS listener is accepting application traffic (witnessed
  // BK-92-F1: undici UND_ERR_SOCKET "other side closed" at leg 2).
  let lastErr = "no attempt";
  const t0 = Date.now();
  while (Date.now() - t0 < 60000) {
    try {
      const res = await fetch(url, { method: "POST", body });
      const json = await res.json();
      if (res.status === 200 && json.access_token) return json;
      lastErr = `status=${res.status} body=${JSON.stringify(json).slice(0, 200)}`;
    } catch (e) {
      lastErr = String(e && e.cause ? e.cause : e).slice(0, 200);
    }
    await sleep(500);
  }
  throw new Error(`STS mint failed (60s budget): ${lastErr}`);
}

function bootRuntime() {
  const p = spawn("mix", ["run", "--no-start", "--no-halt", "workspace/scripts/bk83/boot.exs"], {
    cwd: ROOT,
    env: {
      ...process.env,
      MIX_BUILD_ROOT: "_build-bk83",
      PATH: `${process.env.HOME}/.asdf/installs/elixir/1.20.4-otp-29/bin:${process.env.HOME}/.asdf/installs/erlang/29.1.2/bin:${process.env.PATH}`,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let log = "";
  p.stdout.on("data", (d) => (log += d));
  p.stderr.on("data", (d) => (log += d));
  p.on("exit", (c) => (log += `\n[boot exited ${c}]`));
  return { proc: p, log: () => log };
}

async function main() {
  // Pin the byte-copied smalt.ts egress base at THIS runtime (the copy reads
  // NEXT_PUBLIC_SMALT_EGRESS at import time; default is the shared :8443).
  process.env.NEXT_PUBLIC_SMALT_EGRESS = "http://127.0.0.1:18543";
  installIdbShim();
  const scratch = genEngineScratch();
  const jpath = path.join(scratch, "engine/journal-sync.ts");
  const rpath = path.join(scratch, "engine/receipt.ts");
  const J = await import(jpath);
  const { parseReceiptToken } = await import(rpath);

  for (const port of [18543, 18581]) {
    if (!(await waitPortFree(port, 30000))) {
      console.error(`SUMMARY: port ${port} still occupied by a stale runtime — refusing to boot into it`);
      process.exit(1);
    }
  }
  const rt = bootRuntime();
  if (!(await waitUp(BASE, 240000))) {
    console.error("SUMMARY: substrate never up\n" + rt.log());
    process.exit(2);
  }
  console.log("BOOT_OK :: " + rt.log().split("\n").filter((l) => l.includes("BK83_BOOT_OK")).join(" | "));

  // leg 1: tokenless batch POST -> 401 + WWW-Authenticate
  const r401 = await fetch(SYNC_URL, {
    method: "POST",
    headers: { "Content-Type": "application/octet-stream" },
    body: new Uint8Array(0),
  });
  const www = r401.headers.get("www-authenticate");
  ok(
    "auth.tokenless-401-challenge",
    r401.status === 401 && !!www && www.includes("Bearer"),
    `status=${r401.status} www-authenticate=${www ?? "absent"}`
  );

  // leg 2: real STS mint
  const mint = await stsMint();
  ok(
    "auth.sts-mint",
    typeof mint.access_token === "string" && mint.access_token.split(".").length === 3,
    `expires_in=${mint.expires_in} jws-segments=${mint.access_token.split(".").length}`
  );

  // leg 3: tokenless flushSync -> typed SYNC_HTTP 401
  J.setSyncAuthHeader("");
  await J.appendLocal(CLIENT_ID, 7, new TextEncoder().encode("bk83-leg3-tokenless"));
  const tless = await J.flushSync();
  ok(
    "auth.tokenless-flushSync-refused",
    tless.ok === false && tless.error.code === "SYNC_HTTP" && tless.error.status === 401,
    `ok=${tless.ok} code=${tless.ok ? "-" : tless.error.code} status=${tless.ok ? "-" : tless.error.status}`
  );

  // leg 4: 5 appends -> authenticated flushSync -> 200 + verified receipt
  J.setSyncAuthHeader(mint.access_token);
  // leg 3 already journaled seq 1; four more appends bring the journal to 5.
  for (let i = 2; i <= 5; i++) {
    const a = await J.appendLocal(CLIENT_ID, 7, new TextEncoder().encode(`bk83-app-${i}`));
    if (!a.ok) throw new Error("appendLocal failed: " + JSON.stringify(a.error));
  }
  const fl = await J.flushSync();
  const parsed = fl.ok ? parseReceiptToken(fl.value.receiptToken) : { ok: false };
  ok(
    "sync.flush-5-200-verified",
    fl.ok === true &&
      fl.value.lastSeq === 5 &&
      fl.value.verified === true &&
      fl.value.receiptBytes === 320 &&
      parsed.ok === true &&
      parsed.value.byteLength === 320 &&
      parsed.value.leafCount === 5 &&
      fl.value.markedTo === 5,
    `ok=${fl.ok} lastSeq=${fl.ok ? fl.value.lastSeq : "-"} verified=${fl.ok ? fl.value.verified : "-"} bytes=${parsed.ok ? parsed.value.byteLength : "-"} leaves=${parsed.ok ? parsed.value.leafCount : "-"} markedTo=${fl.ok ? fl.value.markedTo : "-"}`
  );

  const cur = await J.syncedCursor();
  ok(
    "sync.cursor-advanced",
    cur.ok === true && cur.value === 5,
    `cursor=${cur.ok ? cur.value : "-"}`
  );

  // leg 5: 2 more appends, corrupt seq 6 frame client-side -> refusal + snapback
  for (let i = 6; i <= 7; i++) {
    const a = await J.appendLocal(CLIENT_ID, 7, new TextEncoder().encode(`bk83-app-${i}`));
    if (!a.ok) throw new Error("appendLocal failed: " + JSON.stringify(a.error));
  }
  await J.hydrate();
  const un = await J.unacked();
  const victim = un.value.find((s) => s.seqId === 6);
  const frame = new Uint8Array(victim.frame);
  frame[41] ^= 0xff; // first payload byte after the 41-byte header -> CRC breaks
  victim.frame = frame.buffer;
  const flushed = await J.flushSync();
  ok(
    "sync.corruption-typed-refusal",
    flushed.ok === false &&
      flushed.error.code === "SYNC_REFUSED_BY_SERVER" &&
      flushed.error.serverHeadSeq === 5 &&
      flushed.error.purged === 2,
    `code=${flushed.ok ? "-" : flushed.error.code} detail=${flushed.ok ? "-" : flushed.error.detail} serverHeadSeq=${flushed.ok ? "-" : flushed.error.serverHeadSeq} purged=${flushed.ok ? "-" : flushed.error.purged}`
  );

  const curAfter = await J.syncedCursor();
  const hydAfter = await J.hydrate();
  ok(
    "sync.snapback-purge-to-head",
    curAfter.ok && curAfter.value === 5 && hydAfter.ok && hydAfter.value.unsyncedCount === 0,
    `cursor=${curAfter.ok ? curAfter.value : "-"} unsynced=${hydAfter.ok ? hydAfter.value.unsyncedCount : "-"} currentSeq=${hydAfter.ok ? hydAfter.value.currentSeq : "-"}`
  );

  // leg 6: clean re-sync. BK-106 fix landed in the engine: the client P12
  // verify now accumulates over the FULL local frame ledger (the server
  // seals the CUMULATIVE per-client chain — KD-165), so verified is true on
  // every flush, including any flush after the first.
  const a8 = await J.appendLocal(CLIENT_ID, 7, new TextEncoder().encode("bk83-app-clean"));
  if (!a8.ok) throw new Error("appendLocal failed: " + JSON.stringify(a8.error));
  const fl2 = await J.flushSync();
  ok(
    "sync.clean-resync",
    fl2.ok === true &&
      fl2.value.lastSeq === 6 &&
      fl2.value.receiptBytes === 320 &&
      fl2.value.verified === true,
    `ok=${fl2.ok} lastSeq=${fl2.ok ? fl2.value.lastSeq : "-"} bytes=${fl2.ok ? fl2.value.receiptBytes : "-"} p12-verified=${fl2.ok ? fl2.value.verified : "-"} (cumulative ledger verify, KD-165 fix)`
  );

  // leg 6b: cumulative receipt vs the FULL local frame ledger (chain
  // continuity across the snapback — the actual security property).
  const { verifyReceipt } = await import(rpath);
  const ledger = await J.hydrate();
  const vr = ledger.ok
    ? await verifyReceipt(ledger.value.frames, fl2.value.receiptToken)
    : { ok: false };
  ok(
    "sync.cumulative-receipt-vs-full-ledger",
    ledger.ok && vr.ok === true && vr.verified === true &&
      vr.fields.leafCount === ledger.value.frames.length,
    `verified=${vr.ok ? vr.verified : "-"} leafCount=${vr.ok ? vr.fields.leafCount : "-"} localFrames=${ledger.ok ? ledger.value.frames.length : "-"} root=${vr.ok ? vr.fields.rootHex.slice(0, 16) : "-"}`
  );

  const pass = R.filter(Boolean).length;
  const total = R.length;
  console.log(`SUMMARY: ${pass}/${total} PASS, ${total - pass} FAIL`);
  // Await runtime exit (SIGKILL fallback) so the NEXT consecutive run never
  // boots into this run's still-listening beam.
  rt.proc.kill("SIGTERM");
  await new Promise((resolve) => {
    const t = setTimeout(() => {
      rt.proc.kill("SIGKILL");
      resolve();
    }, 10000);
    rt.proc.once("exit", () => {
      clearTimeout(t);
      resolve();
    });
  });
  process.exit(pass === total ? 0 : 1);
}

await main();
