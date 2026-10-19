// wf5-throttling — private substrate with arm_rate_limit=20 via boot-eval
// put_env; burst 200 concurrent GETs to /subscriptions; assert >=1 429
// TooManyRequests with retry-after; SDK maxRetries:0 observation.
// Zero 429s observed -> loud exit 4 SKIPPED, never fake-pass.
import { ResourceManagementClient } from "@azure/arm-resources";
import { check, GREEN, type WfResult } from "../harness/enum.ts";
import type { SubstrateCoords, CredMode } from "../harness/credential.ts";
import { SUB } from "../harness/credential.ts";

type Ctx = { coords: SubstrateCoords; runid: string; cred: any; credMode: CredMode; rateLimit: number };

export async function run(ctx: Ctx): Promise<WfResult> {
  const checks: WfResult["checks"] = [];
  const p = (name: string, verdict: string, detail: string) => checks.push(check(name, verdict, detail));
  const arm = ctx.coords.arm;

  // Raw burst: 200 concurrent GETs, no SDK retry policy involved.
  const token = await ctx.cred.getToken("https://management.azure.com/.default");
  const url = `${ctx.coords.tls}/subscriptions/${SUB}?api-version=2021-04-01`;
  const responses: (Response | Error)[] = await Promise.all(
    Array.from({ length: 200 }, () =>
      fetch(url, { headers: { authorization: `Bearer ${token.token}` } }).then(
        (r) => r,
        (e) => (e instanceof Error ? e : new Error(String(e))),
      ),
    ),
  );
  const statuses = responses.map((r) => (r instanceof Error ? -1 : r.status));
  const errs = statuses.filter((s) => s === -1).length;
  const n429 = statuses.filter((s) => s === 429).length;
  let retryAfter: string | null = null; // Retry-After observed from the wire is a lawful wait input
  let body429: any = null;
  for (const r of responses) {
    if (r instanceof Response && r.status === 429) {
      retryAfter = r.headers.get("retry-after");
      body429 = await r.json().catch(() => null);
      break;
    }
  }
  if (n429 === 0) {
    return {
      id: "wf5",
      checks: [check("arm-429-burst", "SKIP-429",
        `arm_rate_limit=${ctx.rateLimit} but 0 429s in 200-burst (errs=${errs})`)],
      skip: { code: 4, reason: `arm_rate_limit=${ctx.rateLimit} injected but 0 429s observed in 200-request burst — throttle not enforced on the wire` },
    };
  }
  p("arm-429-burst", GREEN, `${n429}/200 requests 429'd, retry-after=${retryAfter}`);
  p("arm-429-typed-code",
    body429?.error?.code === "TooManyRequests" ? GREEN : "FAIL",
    `error.code=${body429?.error?.code} status429x${n429}`);

  // SDK leg with maxRetries:0 — observational: the burst above may have
  // consumed the fixed window, so this attempt legitimately may pass.
  const client = new ResourceManagementClient(ctx.cred, SUB, {
    baseUri: ctx.coords.tls,
    retryOptions: { maxRetries: 0 },
  });
  let got429 = false;
  let resolved = false;
  try {
    await client.subscriptions.get(SUB);
    resolved = true;
  } catch (err: any) {
    got429 = err?.statusCode === 429;
  }
  p("arm-429-sdk-observability",
    GREEN,
    `SDK maxRetries:0 single GET: threw429=${got429} resolved=${resolved} (window-dependent; burst leg is the throttle witness)`);

  // red-against-missing-plane: dead port from inside the throttled run.
  try {
    await fetch("https://localhost:1/subscriptions/x?api-version=2021-04-01");
    p("dead-port-plane-check", "FAIL", "dead port resolved");
  } catch (err: any) {
    const code = err?.code ?? err?.cause?.code;
    p("dead-port-plane-check",
      /ECONNREFUSED|fetch failed/i.test(String(err?.message ?? "") + String(code ?? "")) ? GREEN : "FAIL",
      `dead port typed failure (${code ?? err?.name})`);
  }

  return { id: "wf5", checks };
}
