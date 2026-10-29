#!/usr/bin/env node
/**
 * ATH-2 codec court — plain-node assertion harness (no test framework).
 *
 * Compiles workspace/lib/engine/codec.ts with the workspace's own tsc into a
 * temp outDir, then exercises the wire codec for real:
 *   1. CRC32 check vector ("123456789" -> 0xCBF43926)
 *   2. encode -> decode round-trip (header fields + payload byte-exact)
 *   3. header size is exactly the 41-byte wire contract
 *   4. corrupted payload byte -> typed BAD_CRC32 (never a throw)
 *   5. corrupted magic -> typed BAD_MAGIC
 *   6. truncated frame -> typed SHORT_FRAME
 *   7. declared-length lie -> typed BAD_LEN
 *   8. seq regression -> typed SEQ_REGRESSION under minSeqId
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

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ath2-codec-court-"));
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
  include: [path.join(WS_ROOT, "lib", "engine", "codec.ts")],
};
const cfgPath = path.join(tmp, "tsconfig.json");
fs.writeFileSync(cfgPath, JSON.stringify(tsconfig, null, 2));

const tsc = spawnSync(process.execPath, [TSC, "-p", cfgPath], { encoding: "utf8" });
if (tsc.status !== 0) {
  console.error(`[FAIL] tsc compile of lib/engine/codec.ts:\n${tsc.stdout}${tsc.stderr}`);
  process.exit(1);
}
const codec = await import(
  pathToFileURL(path.join(tmp, "out", "lib", "engine", "codec.js")).href
);

let failures = 0;
function check(name, cond, detail = "") {
  if (cond) {
    console.log(`[PASS] ${name}${detail ? ` — ${detail}` : ""}`);
  } else {
    failures++;
    console.error(`[FAIL] ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

const enc = new TextEncoder();

// 1. CRC32 vector
check(
  "crc32 check vector",
  codec.crc32SelfTest() === true && codec.crc32(enc.encode("123456789")) === 0xcbf43926,
  `crc32("123456789") = 0x${codec.crc32(enc.encode("123456789")).toString(16)}`,
);

// 2-3. round-trip + header size
const payload = enc.encode("opaque-bytes-0123456789");
const clientId = 0x1122334455667788n;
const seq = 7n;
const ts = 1761000000000n;
const frame = codec.encodeFrame(clientId, seq, ts, 2, payload);
check("header is 41 bytes", codec.HEADER_LEN === 41, `HEADER_LEN=${codec.HEADER_LEN}`);
check("frame length", frame.length === 41 + payload.length, `${frame.length} bytes`);
const dec = codec.decodeFrame(frame);
check(
  "round-trip",
  dec.ok === true &&
    dec.value.clientId === clientId &&
    dec.value.seqId === seq &&
    dec.value.ts === ts &&
    dec.value.op === 2 &&
    Buffer.from(dec.value.payload).equals(Buffer.from(payload)),
  dec.ok ? "fields + payload byte-exact" : JSON.stringify(dec.error),
);
check(
  "magic bytes on wire",
  frame[0] === 0x53 && frame[1] === 0x4d && frame[2] === 0x4c && frame[3] === 0x54,
  'magic "SMLT" big-endian at offset 0',
);

// 4. corrupted payload -> BAD_CRC32
const corrupt = frame.slice();
corrupt[corrupt.length - 1] ^= 0xff;
const d4 = codec.decodeFrame(corrupt);
check(
  "corrupt payload -> BAD_CRC32",
  d4.ok === false && d4.error.code === "BAD_CRC32",
  d4.ok ? "decoded!" : `expected=${d4.error.expected.toString(16)} observed=${d4.error.observed.toString(16)}`,
);

// 5. corrupted magic -> BAD_MAGIC
const badMagic = frame.slice();
badMagic[0] = 0x00;
const d5 = codec.decodeFrame(badMagic);
check(
  "corrupt magic -> BAD_MAGIC",
  d5.ok === false && d5.error.code === "BAD_MAGIC",
  d5.ok ? "decoded!" : `observed=0x${d5.error.observed.toString(16)}`,
);

// 6. truncated -> SHORT_FRAME
const d6 = codec.decodeFrame(frame.slice(0, 20));
check(
  "truncated -> SHORT_FRAME",
  d6.ok === false && d6.error.code === "SHORT_FRAME",
  d6.ok ? "decoded!" : `observed=${d6.error.observed}`,
);

// 7. declared-length lie -> BAD_LEN
const lying = frame.slice(0, frame.length - 1);
const d7 = codec.decodeFrame(lying);
check(
  "length lie -> BAD_LEN",
  d7.ok === false && d7.error.code === "BAD_LEN",
  d7.ok ? "decoded!" : `declared=${d7.error.declared} observed=${d7.error.observed}`,
);

// 8. seq regression -> SEQ_REGRESSION
const older = codec.encodeFrame(clientId, 3n, ts, 1, payload);
const d8 = codec.decodeFrame(older, { minSeqId: 7n });
check(
  "seq regression -> SEQ_REGRESSION",
  d8.ok === false && d8.error.code === "SEQ_REGRESSION",
  d8.ok ? "decoded!" : `observed=${d8.error.observed} minimum=${d8.error.minimum}`,
);
const d8b = codec.decodeFrame(older, { minSeqId: 3n });
check("seq equal-to-floor passes", d8b.ok === true, "monotone floor is inclusive");

fs.rmSync(tmp, { recursive: true, force: true });
console.log(`\n# codec court verdict: ${failures === 0 ? "PASS" : "FAIL"} (${failures} failure(s))`);
process.exit(failures === 0 ? 0 : 1);
