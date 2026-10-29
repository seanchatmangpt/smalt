#!/usr/bin/env node
/**
 * BK-GUARDLAW static-law court — a tripwire layer over the runtime courts.
 *
 * The workspace engine's admission laws are enforced at runtime by
 * guard-court / exp1c-journal-court / codec-court / receipt-court. None of
 * them guard the SOURCE SHAPE of the laws: a refactor that silently deletes
 * `SHACL_VERDICT_ABSENT`, the guard's 10s timeout, `ensureClientId` on the
 * append path, the server's `BAD_RESERVED` refusal, or the codec's
 * reserved-zero pad would leave the runtime courts green until the next time
 * someone runs them against the mutated source. This court greps the TS/EX
 * sources for each law's mechanically-checkable shape and fails typed.
 *
 * NOT a replacement for the runtime courts: a static shape check proves the
 * text is present, not that the behavior is correct. It is the cheap first
 * rung; the runtime courts remain the register of truth.
 *
 * Laws checked (per-law manifest):
 *   LAW-1 SHACL-FAILCLOSED : worker evaluateSieve carries the typed
 *          SHACL_VERDICT_ABSENT refusal AND the boolean-type gate on
 *          `conforms` (a missing/ill-typed verdict can never admit).
 *   LAW-2 GUARD-TIMEOUT    : Guard carries a bounded call timeout — the
 *          DEFAULT_CALL_TIMEOUT_MS constant (10s) and the typed
 *          GUARD_TIMEOUT fault detail, consumed in the constructor default.
 *   LAW-3 CLIENTID-PERSIST : `ensureClientId` exists in journal-sync AND is
 *          imported+called on the page append path (useSovereignTerminal).
 *   LAW-4 RESERVED-PAD     : the server frame decoder refuses nonzero pad
 *          typed BAD_RESERVED, and the browser codec pins the 41-byte
 *          header that places the pad at offset 37..41.
 *   LAW-5 CODEC-DISPOSE    : Guard.dispose resolves in-flight admissions
 *          fail-closed (typed fault), never leaves an awaiter hanging.
 *
 * Root override for non-vacuity proofs: LAW_STATIC_COURT_ROOT=<dir>
 * (scratch copy of the tree; the court reads sources under <root>).
 *
 * Exit 0 all laws pass / 1 any law fails (typed).
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO = process.env.LAW_STATIC_COURT_ROOT
  ? path.resolve(process.env.LAW_STATIC_COURT_ROOT)
  : path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

const FILES = {
  worker: path.join(REPO, "workspace/workers/law-reticle.worker.ts"),
  guard: path.join(REPO, "workspace/lib/engine/guard.ts"),
  journal: path.join(REPO, "workspace/lib/engine/journal-sync.ts"),
  terminal: path.join(REPO, "workspace/lib/engine/useSovereignTerminal.ts"),
  codec: path.join(REPO, "workspace/lib/engine/codec.ts"),
  frameEx: path.join(REPO, "lib/smalt/sync/frame.ex"),
};

const failures = [];
const manifest = [];

function law(id, name, fileKey, shapes) {
  const src = fs.readFileSync(FILES[fileKey], "utf8");
  const rows = shapes.map(([label, pattern, flags = "m"]) => [label, new RegExp(pattern, flags), pattern]);
  const missing = rows.filter(([, re]) => !re.test(src));
  const ok = missing.length === 0;
  manifest.push({
    law: ok ? `${id} ${name}` : `${id} ${name}`,
    id,
    name,
    file: path.relative(REPO, FILES[fileKey]),
    checks: rows.map(([label, re]) => ({
      shape: label,
      pattern: re.source,
      present: re.test(src),
    })),
    status: ok ? "PASS" : "FAIL",
  });
  if (!ok) {
    failures.push(
      `${id} ${name}: missing shape(s) in ${path.relative(REPO, FILES[fileKey])} -> ` +
        missing.map(([l, , p]) => `${l} (/${p}/m)`).join("; "),
    );
  }
}

// LAW-1 — SHACL fail-closed admission (worker evaluateSieve).
law("LAW-1", "SHACL-FAILCLOSED", "worker", [
  ["typed-absent-refusal", 'SHACL_VERDICT_ABSENT: conforms field absent from shacl verdict'],
  ["conforms-presence-gate", '"conforms" in r\\.value'],
  ["conforms-boolean-gate", 'typeof r\\.value\\.conforms !== "boolean"'],
  ["false-refuses", "r\\.value\\.conforms === false"],
]);

// LAW-2 — bounded guard call timeout.
law("LAW-2", "GUARD-TIMEOUT", "guard", [
  ["timeout-constant", "DEFAULT_CALL_TIMEOUT_MS = 10_000"],
  ["ctor-default-consumes", 'callTimeoutMs \\?\\? Guard\\.DEFAULT_CALL_TIMEOUT_MS'],
  ["typed-timeout-fault", "GUARD_TIMEOUT: no response within"],
]);

// LAW-3 — persisted per-origin client identity on the append path.
law("LAW-3", "CLIENTID-PERSIST", "terminal", [
  ["import", 'import \\{ ensureClientId \\} from "\\./journal-sync"'],
  ["call", "await ensureClientId\\(\\)"],
]);
law("LAW-3b", "CLIENTID-PERSIST-TURNSTILE", "journal", [
  ["ensureClientId-export", "export async function ensureClientId"],
  ["fifo-turnstile", "clientIdQueue\\.run"],
  ["single-tx-mint", 'transaction\\(\\[CURSOR_STORE\\], "readwrite"'],
]);

// LAW-4 — reserved pad.
law("LAW-4", "RESERVED-PAD", "frameEx", [
  ["server-typed-refusal", '\\{\\:error, \\{\\:bad_frame, "BAD_RESERVED"\\}\\}'],
  ["server-pad-compare", "pad != <<0::32>>"],
]);
law("LAW-4b", "RESERVED-PAD-CODEC", "codec", [
  ["header-contract", "HEADER_LEN = 41"],
  ["pad-stays-zero", "bytes\\[37\\.\\.41\\) stay zero"],
]);

// LAW-5 — fail-closed dispose.
law("LAW-5", "DISPOSE-FAILCLOSED", "guard", [
  ["in-flight-resolve", 'detail: "guard disposed with in-flight admission"'],
  ["timers-cleared", "for \\(const t of this\\.timers\\.values\\(\\)\\) clearTimeout\\(t\\)"],
]);

// --- emit -------------------------------------------------------------------

for (const m of manifest) {
  console.log(`[${m.status}] ${m.law}  (${m.file})`);
  for (const c of m.checks) {
    console.log(`       ${c.present ? "[ok]" : "[MISS]"} ${c.shape}`);
  }
}

if (failures.length > 0) {
  console.error(`\nstatic-law court: ${failures.length} law(s) FAIL`);
  for (const f of failures) console.error(`[FAIL] ${f}`);
  process.exit(1);
}
console.log(`\nstatic-law court: ${manifest.length} laws PASS (tripwire over runtime courts)`);
