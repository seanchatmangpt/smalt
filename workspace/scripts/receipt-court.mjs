#!/usr/bin/env node
/**
 * P12 Constant Seal court — plain-node assertion harness (no framework).
 *
 * Compiles workspace/lib/engine/receipt.ts (+ merkle.ts) with the workspace
 * tsc, then proves the 320-byte receipt invariant and the verify path:
 *   1. minted receipt at n=1 is exactly 320 bytes; parse round-trips fields
 *   2. minted receipt at n=100 is exactly 320 bytes (O(1) seal size)
 *   3. verifyReceipt true path: root over 100 real synthetic leaves matches
 *   4. verifyReceipt false path: any root-byte flip, wrong leafCount, or
 *      non-zero reserved region -> verified false (never a throw)
 *   5. typed parse refusals: BAD_LENGTH, BAD_MAGIC, BAD_VERSION, BAD_ENCODING
 *   6. base64 token of the same 320 bytes parses identically
 *   7. renderReceiptFields drives [data-receipt-bytes]/[data-receipt-verified]
 *
 * Exit 0 only when every assertion holds; exit 1 otherwise.
 */

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const WS_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const TSC = path.join(WS_ROOT, "node_modules", "typescript", "bin", "tsc");

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ath2-receipt-court-"));
fs.symlinkSync(path.join(WS_ROOT, "node_modules"), path.join(tmp, "node_modules"), "dir");
const tsconfig = {
  compilerOptions: {
    outDir: path.join(tmp, "out"),
    rootDir: WS_ROOT,
    module: "commonjs",
    moduleResolution: "node10",
    ignoreDeprecations: "6.0",
    target: "es2022",
    lib: ["es2022", "dom"],
    esModuleInterop: true,
    skipLibCheck: true,
    types: ["node"],
    typeRoots: [path.join(WS_ROOT, "node_modules", "@types")],
  },
  include: [path.join(WS_ROOT, "lib", "engine", "receipt.ts")],
};
const cfgPath = path.join(tmp, "tsconfig.json");
fs.writeFileSync(cfgPath, JSON.stringify(tsconfig, null, 2));

const tsc = spawnSync(process.execPath, [TSC, "-p", cfgPath], { encoding: "utf8" });
if (tsc.status !== 0) {
  console.error(`[FAIL] tsc compile of lib/engine/receipt.ts:\n${tsc.stdout}${tsc.stderr}`);
  process.exit(1);
}
const rc = await import(
  pathToFileURL(path.join(tmp, "out", "lib", "engine", "receipt.js")).href
);
const mk = await import(
  pathToFileURL(path.join(tmp, "out", "lib", "engine", "merkle.js")).href
);

let failures = 0;
function check(name, cond, detail = "") {
  if (cond) {
    console.log(`[ok] ${name}`);
  } else {
    failures += 1;
    console.error(`[FAIL] ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

async function chainRoot(frames) {
  const acc = new mk.Accumulator();
  for (const f of frames) await acc.append(f);
  return acc;
}

const enc = new TextEncoder();

// --- n=1 ---
const acc1 = await chainRoot([enc.encode("leaf-one")]);
const token1 = rc.mintReceiptToken(1, acc1.rootHex());
const bytes1 = rc.parseReceiptToken(token1);
check("n=1 token is 640 hex chars", typeof token1 === "string" && token1.length === 640);
check(
  "n=1 parses ok, byteLength exactly 320",
  bytes1.ok && bytes1.value.byteLength === 320,
  bytes1.ok ? String(bytes1.value.byteLength) : JSON.stringify(bytes1.error),
);
check("n=1 leafCount round-trips", bytes1.ok && bytes1.value.leafCount === 1);
check("n=1 root round-trips", bytes1.ok && bytes1.value.rootHex === acc1.rootHex());
check("n=1 reserved region zero", bytes1.ok && bytes1.value.reservedZero);

// --- n=100: O(1) seal size + true verify path ---
const frames100 = [];
for (let i = 0; i < 100; i++) frames100.push(enc.encode(`synthetic-leaf-${i}`));
const acc100 = await chainRoot(frames100);
const token100 = rc.mintReceiptToken(100, acc100.rootHex());
const bytes100 = rc.parseReceiptToken(token100);
check(
  "n=100 parses ok, byteLength exactly 320 (O(1) seal)",
  bytes100.ok && bytes100.value.byteLength === 320,
  bytes100.ok ? String(bytes100.value.byteLength) : JSON.stringify(bytes100.error),
);
check("n=100 leafCount round-trips", bytes100.ok && bytes100.value.leafCount === 100);
const vr100 = await rc.verifyReceipt(frames100, token100);
check("verifyReceipt true path at n=100", vr100.ok === true && vr100.verified === true, JSON.stringify(vr100));

// --- false paths ---
// flip one hex char inside the root region (bytes 16..47 = hex chars 32..95)
const rootChar = token100[32];
const flipped = token100.slice(0, 32) + (rootChar === "0" ? "1" : "0") + token100.slice(33);
const vrFlip = await rc.verifyReceipt(frames100, flipped);
check("flipped root byte -> verified false", vrFlip.ok === true && vrFlip.verified === false);
const wrongCount = rc.mintReceiptToken(99, acc100.rootHex());
const vrCount = await rc.verifyReceipt(frames100, wrongCount);
check("wrong leafCount -> verified false", vrCount.ok === true && vrCount.verified === false);
const tamperedReserved = rc
  .mintReceiptToken(100, acc100.rootHex())
  .slice(0, 100) + "7f" + rc.mintReceiptToken(100, acc100.rootHex()).slice(102);
const vrReserved = await rc.verifyReceipt(frames100, tamperedReserved);
check("non-zero reserved byte -> verified false", vrReserved.ok === true && vrReserved.verified === false);
const vrWrongFrames = await rc.verifyReceipt([enc.encode("other")], token1);
check("frames not under the receipt -> verified false", vrWrongFrames.ok === true && vrWrongFrames.verified === false);

// --- typed parse refusals ---
const short = rc.parseReceiptToken("abcd");
check("short token -> BAD_LENGTH", !short.ok && short.error.code === "BAD_LENGTH" && short.error.observed === 2);
const badMagic = rc.parseReceiptToken("ff".repeat(320));
check("wrong magic -> BAD_MAGIC", !badMagic.ok && badMagic.error.code === "BAD_MAGIC");
const badVer = rc.parseReceiptToken(token100.slice(0, 8) + "02" + token100.slice(10));
check("wrong version -> BAD_VERSION", !badVer.ok && badVer.error.code === "BAD_VERSION");
const badEnc = rc.parseReceiptToken("zzzz-not-a-token!!");
check("garbage token -> BAD_ENCODING", !badEnc.ok && badEnc.error.code === "BAD_ENCODING");
const notStr = rc.parseReceiptToken(12345);
check("non-string token -> NOT_STRING", !notStr.ok && notStr.error.code === "NOT_STRING");

// --- base64 parity ---
const raw = Buffer.from(token100, "hex");
const b64 = raw.toString("base64");
const viaB64 = rc.parseReceiptToken(b64);
check(
  "base64 of same 320 bytes parses identically",
  viaB64.ok && viaB64.value.byteLength === 320 && viaB64.value.rootHex === acc100.rootHex(),
);

// --- DOM field driver ---
const attrs = new Map();
const el = { setAttribute: (k, v) => attrs.set(k, v) };
rc.renderReceiptFields(el, token100, true);
check(
  "renderReceiptFields sets 320/true on a verified token",
  attrs.get("data-receipt-bytes") === "320" && attrs.get("data-receipt-verified") === "true",
  JSON.stringify([...attrs]),
);
rc.renderReceiptFields(el, "garbage!!", true);
check(
  "renderReceiptFields sets 0/false on a malformed token (parse alone never verifies)",
  attrs.get("data-receipt-bytes") === "0" && attrs.get("data-receipt-verified") === "false",
);

if (failures > 0) {
  console.error(`receipt-court: ${failures} FAIL`);
  process.exit(1);
}
console.log("receipt-court: all assertions passed");
