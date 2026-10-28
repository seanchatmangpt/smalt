#!/usr/bin/env node
// run.mjs — parity orchestrator: reachability gates, suite execution against
// both targets, normalized diff, report. Exit codes per parity/README.md:
// 0 completed (divergences are findings), 1 fatal, 2 smalt down, 3 leg(s)
// loud-skipped, 124 watchdog.
import { mkdir, writeFile, readFile } from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { SMALT, AZURITE, COSMOS_EMULATOR } from "./targets.mjs";
import { runBlobSuite } from "./suites/blob.mjs";
import { runQueueSuite } from "./suites/queue.mjs";
import { runTableSuite } from "./suites/table.mjs";
import { runCosmosSuite } from "./suites/cosmos.mjs";

const WATCHDOG_MS = 300_000;
const OP_TIMEOUT_MS = 30_000;
const RUNID = `${Date.now().toString(36)}-${randomUUID().slice(0, 6)}`;
const REPORT_DIR = process.env.SMALT_PARITY_REPORT_DIR || "parity/reports";

// SLEEP-CLASS: POLL-STEP — watchdog kill-deadline only; owns no coordination.
const watchdog = setTimeout(() => {
  console.error(`[parity] WATCHDOG ${WATCHDOG_MS}ms — exit 124`);
  process.exit(124);
}, WATCHDOG_MS);
watchdog.unref?.();

const log = (...a) => console.log("[parity]", ...a);

// Guard one op: bounded deadline, typed crash record. A crash is a finding
// (recorded and diffed), never a silent skip.
async function guard(name, fn, deadlineMs = OP_TIMEOUT_MS) {
  const deadline = new Promise((_, reject) =>
    setTimeout(() => {
      const e = new Error(`op deadline ${deadlineMs}ms`);
      e.timeout = true;
      reject(e);
    }, deadlineMs).unref?.(),
  );
  try {
    return await Promise.race([fn(), deadline]);
  } catch (e) {
    return {
      outcome: e?.timeout ? "timeout" : "crash",
      status: e?.statusCode ?? 0,
      code: e?.errorCode ?? e?.code ?? null,
      fields: { name: e?.name ?? null, message: String(e?.message ?? "").slice(0, 200) },
    };
  }
}

function diff(suiteRuns) {
  const [a, b] = suiteRuns;
  if (!a || !b) return { verdict: "SKIP", rows: [] };
  const rows = a.records.map((rec, i) => {
    const other = b.records[i];
    const same =
      other &&
      other.op === rec.op &&
      JSON.stringify(normalize(rec)) === JSON.stringify(normalize(other));
    return {
      op: rec.op,
      smalt: summarize(rec),
      reference: other ? summarize(other) : null,
      verdict: same ? "MATCH" : "DIVERGENT",
    };
  });
  return { verdict: rows.some((r) => r.verdict === "DIVERGENT") ? "DIVERGENT" : "MATCH", rows };
}

// Belt-and-braces strip of volatile keys anywhere in the record. Free-text
// error messages are stripped too (stack phrasing always differs) but kept
// in the report via summarize().
const VOLATILE = /^(etag|lastModified|date|requestId|server|host|_ts|_rid|_self|_lsn|_altLink|_attachments|session|contentType|message)$/i;
function normalize(v) {
  if (Array.isArray(v)) return v.map(normalize);
  if (v && typeof v === "object") {
    const out = {};
    for (const [k, val] of Object.entries(v)) {
      if (VOLATILE.test(k)) continue;
      out[k] = normalize(val);
    }
    return out;
  }
  return v;
}

function summarize(rec) {
  if (!rec) return null;
  if (rec.outcome === "error") {
    const msg = rec.fields?.message ? ` (${String(rec.fields.message).slice(0, 80)})` : "";
    return `ERR ${rec.status}${rec.code ? ` ${rec.code}` : ""}${msg}`;
  }
  if (rec.outcome === "crash" || rec.outcome === "timeout") return `${rec.outcome.toUpperCase()} ${rec.fields?.message ?? ""}`;
  const f = rec.fields && Object.keys(rec.fields).length ? ` ${JSON.stringify(rec.fields)}` : "";
  return `${rec.status}${f}`;
}

async function pkgVersion(name) {
  try {
    const pkg = JSON.parse(await readFile(path.resolve(import.meta.dirname, "node_modules", name, "package.json"), "utf8"));
    return pkg.version;
  } catch {
    return "unknown";
  }
}

function markdown(report) {
  const lines = [];
  lines.push(`# parity report ${report.runid}`, "");
  lines.push(`- run: ${report.at} (node ${process.version})`);
  lines.push(`- targets: smalt=${report.env.smalt} azurite=${report.env.azurite} emulator=${report.env.emulator}`);
  lines.push(`- sdks: @azure/storage-blob ${report.sdks.storageBlob}, @azure/storage-queue ${report.sdks.storageQueue}, @azure/data-tables ${report.sdks.dataTables}, @azure/cosmos ${report.sdks.cosmos}`, "");
  for (const s of report.suites) {
    lines.push(`## ${s.suite} — smalt vs ${s.reference} (${s.verdict})`, "");
    lines.push(`| op | smalt | ${s.reference} | verdict |`);
    lines.push(`|---|---|---|---|`);
    for (const r of s.rows) {
      lines.push(`| ${r.op} | \`${r.smalt}\` | \`${r.reference}\` | ${r.verdict} |`);
    }
    lines.push("");
    const divergent = s.rows.filter((r) => r.verdict === "DIVERGENT");
    if (divergent.length) {
      lines.push(`### divergences (${divergent.length})`, "");
      for (const d of divergent) lines.push(`- **${d.op}**: smalt \`${d.smalt}\` vs ${s.reference} \`${d.reference}\``);
      lines.push("");
    }
  }
  lines.push(`## summary`, "");
  lines.push(`- ops: ${report.summary.total}, match: ${report.summary.match}, divergent: ${report.summary.divergent}, skipped-legs: ${report.summary.skippedLegs}`);
  lines.push(`- verdict: **${report.summary.verdict}** — divergences are findings for the KD register, not harness failures.`);
  return lines.join("\n");
}

async function main() {
  const wanted = process.argv.slice(2).filter((a) => !a.startsWith("-"));
  const suites = wanted.length ? wanted : ["blob", "queue", "table", "cosmos"];
  log(`runid=${RUNID} suites=${suites.join(",")}`);

  if (!(await SMALT.probe())) {
    console.error("[parity] smalt substrate not answering (anonymous ARM /metadata/endpoints) — exit 2");
    process.exit(2);
  }
  log("smalt ownership gate: PASS");

  const skippedLegs = [];
  const report = {
    runid: RUNID,
    at: new Date().toISOString(),
    env: {
      smalt: `${SMALT.armBase} + ${SMALT.egressBase}`,
      azurite: AZURITE.blobBase,
      emulator: COSMOS_EMULATOR.endpoint,
    },
    sdks: {
      storageBlob: await pkgVersion("@azure/storage-blob"),
      storageQueue: await pkgVersion("@azure/storage-queue"),
      dataTables: await pkgVersion("@azure/data-tables"),
      cosmos: await pkgVersion("@azure/cosmos"),
    },
    suites: [],
  };

  const azuriteUp = await AZURITE.probe();

  // Storage-family suites (blob / queue / table) share the Azurite target.
  const storageSuites = {
    blob: { fn: runBlobSuite, mk: (t) => ({ svc: t.blob(), runid: RUNID }) },
    queue: { fn: runQueueSuite, mk: (t) => ({ svc: t.queue(), runid: RUNID }) },
    table: { fn: runTableSuite, mk: (t) => ({ ...t.tableCoords(), runid: RUNID }) },
  };
  for (const name of ["blob", "queue", "table"].filter((s) => suites.includes(s))) {
    const { fn, mk } = storageSuites[name];
    if (!azuriteUp) skippedLegs.push(`${name}/azurite`);
    const legs = [{ target: SMALT, args: mk(SMALT) }];
    if (azuriteUp) legs.push({ target: AZURITE, args: mk(AZURITE) });
    const runs = await runSuites(name, legs, fn);
    report.suites.push(buildSuite(name, "azurite", runs, azuriteUp));
  }

  if (suites.includes("cosmos")) {
    let emulatorUp = false;
    try {
      emulatorUp = await COSMOS_EMULATOR.probe();
    } catch {
      emulatorUp = false;
    }
    const dbId = `parity-${RUNID}`;
    const legs = [];
    legs.push({
      target: SMALT,
      args: { ...(await SMALT.cosmosAdapter(dbId, "probe")), runid: RUNID },
      cleanup: async (a) => a.container.delete().catch(() => {}),
    });
    if (emulatorUp) {
      try {
        legs.push({
          target: COSMOS_EMULATOR,
          args: { ...(await COSMOS_EMULATOR.cosmosAdapter(dbId, "probe")), runid: RUNID },
          cleanup: async (a) => a.client.database(dbId).delete().catch(() => {}),
        });
      } catch (e) {
        log(`cosmos/emulator leg skipped loudly: adapter failed (${String(e?.message ?? e).slice(0, 120)})`);
        emulatorUp = false;
      }
    }
    if (!emulatorUp) skippedLegs.push("cosmos/emulator");
    const runs = await runSuites("cosmos", legs, runCosmosSuite);
    report.suites.push(buildSuite("cosmos", "emulator", runs, emulatorUp));
    for (const leg of legs) await leg.cleanup?.(leg.args);
  }

  const summary = { total: 0, match: 0, divergent: 0, skippedLegs };
  for (const s of report.suites) {
    summary.total += s.rows.length;
    summary.match += s.rows.filter((r) => r.verdict === "MATCH").length;
    summary.divergent += s.rows.filter((r) => r.verdict === "DIVERGENT").length;
  }
  summary.verdict = skippedLegs.length
    ? "PARTIAL"
    : summary.divergent
      ? "DIVERGENCES FOUND"
      : "FULL MATCH";
  report.summary = summary;

  const dir = path.resolve(REPORT_DIR, RUNID);
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, "report.json"), JSON.stringify(report, null, 2));
  await writeFile(path.join(dir, "report.md"), markdown(report));
  console.log(markdown(report));
  log(`report: ${dir}`);

  if (skippedLegs.length) process.exit(3);
  process.exit(0);
}

// Shared runner for both suites: guard per target, keep raw records. The
// cosmos suite runs with a longer deadline (emulator first-write warm-up).
async function runSuites(suite, legs, suiteFn) {
  const deadlineMs = suite === "cosmos" ? 90_000 : 30_000;
  const runs = [];
  for (const leg of legs) {
    const out = await guard(`${suite}/${leg.target.id}`, () => suiteFn(leg.args), deadlineMs);
    runs.push({
      target: leg.target.id,
      records: out?.records ?? [
        {
          op: `${suite}-suite`,
          outcome: out?.outcome ?? "crash",
          status: out?.status ?? 0,
          code: out?.code ?? null,
          fields: { message: out?.fields?.message ?? "suite crashed" },
        },
      ],
    });
  }
  return runs;
}

function buildSuite(suite, referenceLabel, runs, referenceUp) {
  if (!referenceUp) {
    return {
      suite,
      reference: referenceLabel,
      verdict: "SKIP",
      rows: (runs[0]?.records ?? []).map((r) => ({ op: r.op, smalt: summarize(r), reference: "SKIPPED (target down)", verdict: "SKIP" })),
    };
  }
  const d = diff(runs);
  return { suite, reference: referenceLabel, verdict: d.verdict, rows: d.rows };
}

main().catch((e) => {
  console.error("[parity] fatal:", e);
  process.exit(1);
});
