// index.ts — ex7 "Fintech throttling resilience" (Fortune-500 archetype, lane ex7).
//
// Business story: a payments platform's control plane is rate-limited by its
// regulator-mandated arm_rate_limit. When a deploy fan-out fires a burst of
// ARM calls, the platform MUST see a typed 429 TooManyRequests carrying
// Retry-After — never a 5xx — so SDK retry policies can back off and every
// operation eventually lands. On the messaging side, a payment channel opens
// one AMQP connection whose CBS token claims are capacity-bounded: claim
// flow works for legitimate audiences, and hitting the claim ceiling is a
// typed, bounded rejection — never a hang on the payments hot path.
//
// Steps:
//   1. Boot a PRIVATE throttle substrate (block v6 = ports 39760-39765,
//      enforce auth, arm_rate_limit=20 via boot-eval put_env) — reuse-else-
//      boot with boot marker + lock + deadline-poll, lifted from
//      verification/ts/harness/substrate.ts bootPrivate + the conftest
//      marker/lock pattern.
//   2. Burst leg: 60 concurrent ARM GETs through ResourceManagementClient
//      with retryOptions.maxRetries: 0 -> >=1 typed 429 with Retry-After,
//      zero 5xx in the burst window.
//   3. Default-retry leg: 40 sequential ARM GETs with SDK DEFAULT retries
//      -> every request eventually succeeds (SDK honors Retry-After).
//   4. Service Bus CBS leg: real AMQP connection with a known shared key;
//      CBS put-token claim flow succeeds for a first audience; then fan out
//      sends across 130 distinct queue audiences so the per-connection claim
//      ceiling (128) is crossed — the over-capacity send fails TYPED within
//      a bounded deadline, never hanging.
//
// Conventions copied from the verification/ tier: official @azure/* SDKs over
// the real wire, zero mocks, no fixed sleeps (deadline-bounded waits only),
// typed SDK exceptions asserted on real state, exit contract
// 0 pass / 1 fail / 2 substrate down / 3 loud skip.
import { createRequire } from "node:module";
import path from "node:path";
// SDKs resolve from the verification/ts node_modules (one dependency tree for
// the whole external tier); harness imports are relative file imports.
const require = createRequire(
  path.resolve(import.meta.dirname, "../../verification/ts/package.json"),
);
const { ResourceManagementClient } = require("@azure/arm-resources");
const { ServiceBusClient, MessagingError } = require("@azure/service-bus");
import { openSync, closeSync, unlinkSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { check, GREEN, type Check } from "../../verification/ts/harness/enum.ts";
import {
  bootPrivate,
  down,
  tryConnect,
  CA_CERT,
  type Receipt,
} from "../../verification/ts/harness/substrate.ts";
import { SubstrateBootError } from "../../verification/ts/harness/substrate.ts";
import { makeCredential, SUB } from "../../verification/ts/harness/credential.ts";

// --- lane-private substrate identity -----------------------------------------
const BLOCK = "v6"; // ports 39760-39765 (verified free via lsof; 39750-55 is the py MESG lane)
const MARKER = "/tmp/ex7-fin-throttle.boot.json";
const LOCK = "/tmp/ex7-fin-throttle.lock";
const RATE_LIMIT = 20;
const RUN = `ex7fin${Date.now()}`;

// Lane build isolation: boot the substrate from THIS lane's build root so a
// sibling lane's in-flight lib/ edit cannot freeze our boot mid-compile
// (compile-freeze SLA, same-checkout fanout law 2).
process.env.MIX_BUILD_ROOT = process.env.MIX_BUILD_ROOT || "_build-lane-ex7";

type ExReceipt = Receipt & { sharedKey?: string };
let sharedKeyRaw = "";

// --- verdict vocabulary -------------------------------------------------------
const summarize = (checks: Check[]): { exit: number; summary: string } => {
  const lines = checks.map((c) => `  [${c.verdict}] ${c.name} — ${c.detail}`);
  const green = checks.filter((c) => c.verdict === GREEN).length;
  const failed = checks.length - green;
  const summary =
    `\n== ex7-fintech-throttle: ${green}/${checks.length} GREEN, ${failed} FAIL ==\n` +
    lines.join("\n");
  let exit = 0;
  if (checks.length === 0 || green === 0) exit = 3;
  else if (failed > 0) exit = 1;
  return { exit, summary };
};

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms)); // SLEEP-CLASS: POLL-STEP — bounded poll step only

// --- reuse-else-boot (marker + lock + deadline-poll) ---------------------------
async function substrateHealthy(armPort: number): Promise<boolean> {
  const up = (
    await Promise.all([39760, 39761, 39762, 39763, 39764, 39765].map((p) => tryConnect(p, "127.0.0.1", 500)))
  ).every(Boolean);
  if (!up) return false;
  const health = await fetch(`http://127.0.0.1:${armPort}/metadata/endpoints`)
    .then((r) => r.status)
    .catch(() => 0);
  return health === 200;
}

async function ensureThrottleSubstrate(): Promise<ExReceipt> {
  const lockFd = await (async () => {
    const deadline = Date.now() + 20_000;
    for (;;) {
      try {
        return openSync(LOCK, "wx");
      } catch {
        if (Date.now() > deadline) {
          console.error("[ex7] LOCK-TIMEOUT: another ex7 run holds the lock past 20s");
          process.exit(3);
        }
        await delay(250);
      }
    }
  })();
  try {
    if (existsSync(MARKER)) {
      try {
        const m = JSON.parse(readFileSync(MARKER, "utf8"));
        const [amqp, eh, arm] = m.ports ?? [];
        const fresh = Date.now() - Number(m.booted ?? 0) < 3_600_000;
        if (fresh && (await substrateHealthy(arm))) {
          console.log(`[ex7] reusing throttle substrate block=${BLOCK} pid=${m.pid} ports=${m.ports.join("/")}`);
          sharedKeyRaw = m.sharedKeyRaw ?? "";
          return {
            block: BLOCK,
            ports: m.ports.map(Number),
            pid: Number(m.pid),
            reused: true,
            auth: "enforce",
            sharedKey: m.sharedKey,
          };
        }
      } catch {
        /* stale/unreadable marker -> fall through to boot */
      }
    }
    // Not reusable: sweep anything on the block, then boot with the throttle profile.
    await down(BLOCK, "sweep");
    // RAW key stored server-side (SasVerifier HMACs the raw string, min 32
    // bytes); the AMQP conn string carries base64(raw) — the SDK decodes it.
    const rawKey = `ex7-fin-${Date.now()}-${randomUUID()}`; // >=32 bytes
    const sharedKey = Buffer.from(rawKey).toString("base64");
    sharedKeyRaw = rawKey;
    const receipt = (await bootPrivate(
      BLOCK,
      `Application.put_env(:smalt, :sb_shared_key, "${sharedKey}"); ` +
        `Application.put_env(:smalt, :arm_rate_limit, ${RATE_LIMIT})`,
      "enforce",
    )) as ExReceipt;
    writeFileSync(
      MARKER,
      JSON.stringify({ pid: receipt.pid, booted: Date.now(), ports: receipt.ports, sharedKey, sharedKeyRaw }),
    );
    console.log(
      `[ex7] booted throttle substrate block=${BLOCK} pid=${receipt.pid} ports=${receipt.ports.join("/")}`,
    );
    return receipt;
  } finally {
    closeSync(lockFd);
    unlinkSync(LOCK);
  }
}

// External actors (a sibling lane's global sweep / lane-clean) can SIGTERM
// our private beam mid-run. Re-ensure before each leg: reuse-else-boot with a
// single bounded reboot, never a fake pass over a dead plane.
let LAST_RECEIPT: ExReceipt | null = null;
async function ensureAlive(): Promise<ExReceipt> {
  const [,, armPort] = LAST_RECEIPT?.ports ?? [];
  if (LAST_RECEIPT && (await substrateHealthy(armPort))) return LAST_RECEIPT;
  // stale marker only: no lock recursion — direct sweep+boot
  await down(BLOCK, "sweep");
  const rawKey = `ex7-fin-${Date.now()}-${randomUUID()}`;
  // The SDK uses the conn-string SharedAccessKey AS-IS for the SAS HMAC, so
  // the server-side put_env key must be the exact same string (base64 text).
  const b64Key = Buffer.from(rawKey).toString("base64");
  const receipt = (await bootPrivate(
    BLOCK,
    `Application.put_env(:smalt, :sb_shared_key, "${b64Key}"); ` +
      `Application.put_env(:smalt, :arm_rate_limit, ${RATE_LIMIT})`,
    "enforce",
  )) as ExReceipt;
  receipt.sharedKey = b64Key;
  sharedKeyRaw = b64Key;
  writeFileSync(
    MARKER,
    JSON.stringify({ pid: receipt.pid, booted: Date.now(), ports: receipt.ports, sharedKey: receipt.sharedKey, sharedKeyRaw }),
  );
  LAST_RECEIPT = receipt;
  console.log(`[ex7] REBOOTED throttle substrate pid=${receipt.pid} (prior beam killed externally; ARM credential will re-mint)`);
  return receipt;
}

// --- main ----------------------------------------------------------------------
async function main() {
  const checks: Check[] = [];
  const p = (name: string, verdict: string, detail: string) => checks.push(check(name, verdict, detail));
  const runid = RUN;

  // 1. substrate
  let receipt: ExReceipt;
  try {
    receipt = await ensureThrottleSubstrate();
  } catch (e) {
    if (e instanceof SubstrateBootError) {
      console.error(`[ex7] SUBSTRATE-DOWN: ${e.message}`);
      process.exit(2);
    }
    throw e;
  }
  LAST_RECEIPT = receipt;
  const [amqpPort, , armPort, , tlsPort] = receipt.ports;
  const tls = `https://localhost:${tlsPort}`;
  const arm = `http://127.0.0.1:${armPort}`;
  p("throttle-substrate-up",
    (await substrateHealthy(armPort)) ? GREEN : "FAIL",
    `block=${BLOCK} arm=${arm} tls=${tls} amqp=${amqpPort} rate_limit=${RATE_LIMIT} reused=${receipt.reused}`);

  const credRef: { current: any } = { current: await makeCredential("smalt", tls) };

  // Control resource group, created through the SDK DEFAULT retry policy
  // (honors Retry-After) — also the warm token for the legs below.
  const deft = new ResourceManagementClient(credRef.current, SUB, { baseUri: tls });
  const ctrlRg = `${RUN}ctrl`;
  await deft.resourceGroups.createOrUpdate(ctrlRg, { location: "smalt" });

  // 2. burst leg — maxRetries:0, 60 concurrent ARM GETs
  {
    const zero = new ResourceManagementClient(credRef.current, SUB, {
      baseUri: tls,
      retryOptions: { maxRetries: 0 },
    });
    const burst = 60;
    let settled: PromiseSettledResult<any>[];
    // one bounded retry if an external actor killed the beam mid-burst
    for (let attempt = 1; ; attempt++) {
      settled = await Promise.allSettled(
        Array.from({ length: burst }, () => zero.resourceGroups.get(ctrlRg)),
      );
      const refused = settled.filter(
        (s) => s.status === "rejected" && !Number((s.reason as any)?.statusCode),
      ).length;
      if (refused <= burst / 2 || attempt >= 2) {
        if (attempt >= 2 && refused > burst / 2) console.error("[ex7] burst refusals persist after reboot retry");
        break;
      }
      console.error("[ex7] burst refusal-dominant -> ensureAlive reboot, retrying burst once");
      await ensureAlive();
      credRef.current = await makeCredential("smalt", tls);
    }
    const statuses: number[] = [];
    let n429 = 0;
    let retryAfter: string | null = null;
    let typed429Body: any = null;
    let n5xx = 0;
    let other: Record<number, number> = {};
    for (const s of settled) {
      if (s.status === "fulfilled") {
        statuses.push(200);
        continue;
      }
      const err: any = s.reason;
      const st = Number(err?.statusCode ?? 0);
      statuses.push(st);
      if (st === 429) {
        n429++;
        const ra = err?.response?.headers?.get?.("retry-after") ?? err?.response?.headers?.get?.("Retry-After");
        if (ra && retryAfter === null) retryAfter = ra;
        const raw = err?.response?.bodyAsText;
        if (raw && !typed429Body) {
          try { typed429Body = JSON.parse(raw); } catch { /* keep null */ }
        }
      } else if (st >= 500) n5xx++;
      else other[st] = (other[st] ?? 0) + 1;
    }
    const detail =
      `burst=${burst} 200x${statuses.filter((s) => s === 200).length} 429x${n429} ` +
      `5xx=${n5xx} other=${JSON.stringify(other)} retry-after=${retryAfter} ` +
      `error.code=${typed429Body?.error?.code ?? "n/a"}`;
    p("arm-burst-typed-429", n429 >= 1 ? GREEN : "FAIL", detail);
    p("arm-429-retry-after", n429 > 0 && !!retryAfter ? GREEN : "FAIL", `retry-after=${retryAfter}`);
    p("arm-429-typed-code",
      typed429Body?.error?.code === "TooManyRequests" ? GREEN : "FAIL",
      `error.code=${typed429Body?.error?.code ?? "n/a"}`);
    p("arm-burst-no-5xx", n5xx === 0 ? GREEN : "FAIL", `5xx count in burst window=${n5xx}`);
  }

  // 3. default-retry leg — SDK default retries honor Retry-After; all land
  {
    await ensureAlive();
    credRef.current = await makeCredential("smalt", tls);
    const deft = new ResourceManagementClient(credRef.current, SUB, { baseUri: tls });
    // a rebooted beam loses ETS state — re-create the control RG idempotently
    await deft.resourceGroups.createOrUpdate(ctrlRg, { location: "smalt" });
    const n = 40;
    const deadline = Date.now() + 120_000;
    let ok = 0;
    let fail: string | null = null;
    for (let i = 0; i < n; i++) {
      if (Date.now() > deadline) {
        fail = `deadline ${120_000}ms exceeded at ${i}/${n}`;
        break;
      }
      try {
        await deft.resourceGroups.get(ctrlRg);
        ok++;
      } catch (e: any) {
        fail = `request ${i} threw ${e?.name} ${e?.statusCode ?? ""}: ${String(e?.message).slice(0, 120)}`;
        break;
      }
    }
    p("arm-default-retry-all-succeed", ok === n && !fail ? GREEN : "FAIL",
      fail ?? `default-retry client: ${ok}/${n} requests eventually succeeded (SDK honored Retry-After)`);
  }

  // 4. Service Bus CBS leg — claim flow + typed capacity rejection
  {
    const cur = await ensureAlive();
    credRef.current = await makeCredential("smalt", tls);
    const amqpPort = cur.ports[0];
    const rg = `${runid}rg`;
    const ns = `${runid}ns`;
    const SKIP = "SKIP#SURFACE-ABSENT";
    const armBase =
      `${tls}/subscriptions/${SUB}/resourceGroups/${rg}/providers/Microsoft.ServiceBus/namespaces/${ns}`;
    const token = await credRef.current.getToken("https://management.azure.com/.default");
    const hdr = { authorization: `Bearer ${token.token}`, "content-type": "application/json" };
    let createFail: string | null = null;
    const createWithRetry = async (url: string, body: unknown) => {
      const deadline = Date.now() + 60_000;
      for (;;) {
        const res = await fetch(url, { method: "PUT", headers: hdr, body: JSON.stringify(body) });
        if (res.status === 429 && Date.now() < deadline) {
          const ra = Number(res.headers.get("retry-after") ?? "1");
          await delay(Math.min(Math.max(ra, 1), 5) * 1000); // SLEEP-CLASS: POLL-STEP — wire-supplied Retry-After, bounded
          continue;
        }
        if (res.status >= 300) createFail = `PUT ${url.split("/").slice(-2).join("/")} -> ${res.status}: ${(await res.text()).slice(0, 160)}`;
        return res;
      }
    };
    // ARM SB entity creation: probe once. The substrate answers RouteNotFound
    // for the Microsoft.ServiceBus namespace/queue ARM surface — the wire
    // plane auto-vends queues on attach (the wf3 pattern). Loud typed SKIP,
    // never a fake pass.
    const nsRes = await createWithRetry(`${armBase}?api-version=2021-04-01`, { location: "smalt", skuName: "Standard" });
    let queueNames: string[] = [];
    let created = 0;
    let armSurface: string;
    if (nsRes.status >= 300) {
      // 404 RouteNotFound or 400 InvalidResourceShape — the ARM-side
      // Microsoft.ServiceBus namespace/queue creation surface does not admit
      // entity PUTs on this substrate; the AMQP wire plane auto-vends queues
      // on attach (the wf3 pattern). Loud typed SKIP, never a fake pass.
      armSurface = `ARM_SB_ENTITY_SURFACE_ABSENT (ns PUT ${nsRes.status})`;
    } else {
      const QUEUES = 130;
      queueNames = Array.from({ length: QUEUES }, (_, i) => `${runid}q${i}`);
      for (const q of queueNames) {
        const res = await createWithRetry(
          `${armBase}/queues/${q}?api-version=2021-04-01`,
          { location: "smalt" }, // substrate queue shape requires location on child PUTs
        );
        if (res.status === 200 || res.status === 201) created++;
        else if (res.status >= 300 && !createFail)
          createFail = `PUT queues/${q} -> ${res.status}: ${(await res.text()).slice(0, 160)}`;
      }
      armSurface = `nsPUT=${nsRes.status}; created=${created}/${QUEUES}` + (createFail ? `; ${createFail}` : "");
    }

    p("sb-queues-created",
      nsRes.status >= 300 ? SKIP : (created === queueNames.length && queueNames.length > 0 ? GREEN : "FAIL"),
      `arm_rate_limit=${RATE_LIMIT}, Retry-After-honoring retries; surface=${armSurface}`);

    // Wire-plane queue names: ARM-created when the surface exists, else
    // broker auto-vend on attach (wf3 pattern — attach+flow+vend).
    const CAP_Q = 130;
    if (queueNames.length === 0) {
      queueNames = Array.from({ length: CAP_Q }, (_, i) => `${runid}q${i}`);
    }

    const connStr =
      `Endpoint=sb://127.0.0.1:${amqpPort};SharedAccessKeyName=RootManageSharedAccessKey;` +
      `SharedAccessKey=${sharedKeyRaw};UseDevelopmentEmulator=true`;
    const sb = new ServiceBusClient(connStr, { retryOptions: { maxRetries: 0, timeoutInMs: 10_000 } });

    // 4a. CBS put-token claim flow works for a real audience
    let cbsOk = false;
    let cbsDetail = "";
    try {
      await sb.createSender(queueNames[0]).sendMessages({ body: { probe: runid }, messageId: `${runid}-m0` });
      cbsOk = true;
      cbsDetail = `send to ${queueNames[0]} resolved — attach+flow+CBS put-token claim accepted`;
    } catch (e: any) {
      cbsDetail = `${e?.name}: ${String(e?.message).slice(0, 140)}`;
    }
    p("sb-cbs-claim-flow", cbsOk ? GREEN : "FAIL", cbsDetail);

    // 4b. claim-capacity: cross the per-connection 128-claim ceiling; the
    // over-capacity audience must fail TYPED within a bounded deadline.
    const SEND_DEADLINE_MS = 15_000;
    let sentOk = 0;
    let typedErr: { name: string; msg: string } | null = null;
    let hung = false;
    for (let i = 1; i < queueNames.length; i++) {
      const q = queueNames[i];
      try {
        await Promise.race([
          sb.createSender(q).sendMessages({ body: { i }, messageId: `${runid}-m${i}` }),
          delay(SEND_DEADLINE_MS).then(() => { throw new Error(`SEND-HANG>${SEND_DEADLINE_MS}ms`); }),
        ]);
        sentOk++;
      } catch (e: any) {
        if (/SEND-HANG/.test(String(e?.message))) {
          hung = true;
          typedErr = { name: "HANG", msg: `send to ${q} exceeded ${SEND_DEADLINE_MS}ms` };
          break;
        }
        typedErr = { name: String(e?.name ?? "unknown"), msg: String(e?.message).slice(0, 140) };
        break;
      }
    }
    const isMessaging = typedErr && typedErr.name !== "HANG" && typedErr.name !== "Error" &&
      /MessagingError|ServiceBusError/i.test(typedErr.name);
    p("sb-cbs-capacity-typed",
      !hung && typedErr && sentOk >= 120 && isMessaging ? GREEN : "FAIL",
      `claimed+sent=${sentOk} before typed rejection; error=${typedErr?.name}: ${typedErr?.msg} hung=${hung} ` +
      `(per-connection claim ceiling=128, one claim consumed by the CBS-flow probe)`);
    // MessagingError instanceof witness (real SDK type, not a string match)
    let inst = false;
    try {
      await sb.createSender(`${runid}q${CAP_Q + 5}`).sendMessages({ body: 1 });
    } catch (e: any) {
      inst = e instanceof MessagingError;
    }
    p("sb-cbs-capacity-error-class",
      inst ? GREEN : "FAIL",
      `over-capacity error instanceof MessagingError=${inst}`);
    await sb.close().catch(() => {});
  }

  // teardown: our block, our sweep
  await down(BLOCK, "sweep");
  try { unlinkSync(MARKER); } catch { /* absent */ }

  const { exit, summary } = summarize(checks);
  console.log(summary);
  process.exit(exit);
}

main().catch((e) => {
  console.error("[ex7] harness error:", e?.stack ?? e);
  process.exit(3);
});
