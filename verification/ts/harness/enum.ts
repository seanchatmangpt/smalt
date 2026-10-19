// enum.ts — closed surface-enum verdict vocabulary + per-workflow rollup.
export const GREEN = "GREEN";
export const RD = (kd: string) => `REGISTERED-DIVERGENCE#${kd}`;

export type Check = {
  name: string;
  verdict: string; // GREEN | REGISTERED-DIVERGENCE#KD-nn
  detail: string;
};

export type WfResult = {
  id: string;
  checks: Check[];
  skip?: { code: number; reason: string }; // loud SKIP (exit 3 / exit 4)
};

export function rollup(wf: WfResult): { ok: boolean; summary: string } {
  const green = wf.checks.filter((c) => c.verdict === GREEN).length;
  const rd = wf.checks.filter((c) => c.verdict.startsWith("REGISTERED-DIVERGENCE"));
  const lines: string[] = [];
  for (const c of wf.checks) {
    lines.push(`  [${c.verdict}] ${c.name} — ${c.detail}`);
  }
  const summary =
    `\n== ${wf.id}: ${green}/${wf.checks.length} GREEN, ${rd.length} REGISTERED-DIVERGENCE ==\n` +
    lines.join("\n") +
    (wf.skip ? `\n  [SKIP exit ${wf.skip.code}] ${wf.skip.reason}` : "");
  const ok = wf.checks.every((c) => c.verdict === GREEN || c.verdict.startsWith("REGISTERED-DIVERGENCE"));
  return { ok: ok && !wf.skip, summary };
}

export function check(name: string, verdict: string, detail: string): Check {
  return { name, verdict, detail };
}
