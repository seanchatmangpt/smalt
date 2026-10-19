// wfmain.ts — workflow child-process entry: builds ctx from env, runs the
// named workflow, prints the result JSON as the LAST stdout line, and maps
// failures to the exit contract (0 ok / 1 check failure / 2 substrate-down
// typed through SubstrateBootError / 3 loud skip incl. azure credential /
// 4 throttle-not-enforced).
const wf = process.argv[2];
if (!wf || !/^wf[1-5]$/.test(wf)) {
  console.error("usage: node harness/wfmain.ts wfN");
  process.exit(3);
}

const coords = {
  arm: process.env.SMALT_TS_ARM ?? '',
  tls: process.env.SMALT_TS_TLS ?? '',
  egress: process.env.SMALT_TS_EGRESS ?? '',
  amqpPort: Number(process.env.SMALT_TS_AMQP_PORT),
  ehPort: Number(process.env.SMALT_TS_EH_PORT),
};

const credMode: "smalt" | "azure" = process.env.SMALT_TS_CREDENTIAL === "azure" ? "azure" : "smalt";
const { makeCredential } = await import("./credential.ts");
const ctx: any = {
  coords,
  runid: process.env.SMALT_TS_RUNID ?? "dev",
  credMode,
  rateLimit: Number(process.env.SMALT_TS_RATE_LIMIT ?? 0),
};
try {
  ctx.cred = await makeCredential(credMode, coords.tls);
} catch (e: any) {
  if (e?.skipCode === 3) {
    console.error(`[wfmain] ${e.message}`);
    process.exit(3);
  }
  throw e;
}

const mod = await import(`../${wf}/index.ts`);
try {
  const result = await mod.run(ctx);
  const skip = result.skip?.code;
  console.log(JSON.stringify(result));
  process.exit(skip ?? 0);
} catch (e: any) {
  console.error(`[wfmain] ${wf} crashed: ${e?.stack ?? e}`);
  process.exit(1);
}
