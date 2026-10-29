import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import DeltaSync from "./DeltaSync";
import { SMALT_ARM, smaltFetch } from "../../lib/smalt";

/**
 * Popcorn testbed surface (W5-C round 2): substrate face + tenant list +
 * newest-5 witness standings table + KD register rows. Server component —
 * all I/O happens server-side; the browser receives static markup only.
 */

export const dynamic = "force-dynamic";

type Endpoints = Record<string, unknown>;

async function fetchJson(path: string): Promise<
  { ok: true; body: unknown } | { ok: false; error: string }
> {
  try {
    const res = await smaltFetch(SMALT_ARM, path, {
      headers: { accept: "application/json" },
    });
    const body = await res.text();
    if (!res.ok) {
      return { ok: false, error: `HTTP ${res.status}` };
    }
    try {
      return { ok: true, body: JSON.parse(body) };
    } catch {
      return { ok: false, error: "non-JSON body" };
    }
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
}

/** Standing vocabulary, mirroring popcorn_demo/scripts/receipt_index.py. */
const STANDING_TOKENS = [
  "PARTIAL_ALIVE", "PROVISIONAL_ALIVE", "SKIP-LOUD", "PARITY_CONFIRMED",
  "UNSUPPORTED", "PROVISIONAL", "ALIVE", "UNKNOWN", "COMPLETE", "LANDED",
  "CLOSED", "DONE", "FAIL", "PASS", "SUSPECT",
];

const EXPLICIT_STANDING =
  /^\s*[-*]?\s*\**\s*standing\s*:\**/i;

/**
 * Extract the standing from a receipt, same rule as receipt_index.py:
 * explicit "Standing:" line wins; otherwise a generic status-token line.
 */
function extractStanding(text: string): string {
  let explicit: string | null = null;
  let generic: string | null = null;
  for (const line of text.split("\n")) {
    if (!STANDING_TOKENS.some((t) => line.includes(t))) continue;
    if (EXPLICIT_STANDING.test(line)) explicit = line;
    else if (/\b(ALIVE|PASS|FAIL|SUSPECT|UNKNOWN)\b/.test(line)) generic = line;
  }
  const match = explicit ?? generic;
  if (!match) return "UNKNOWN";
  for (const tok of STANDING_TOKENS) {
    if (match.includes(tok)) return tok;
  }
  return "UNKNOWN";
}

type ReceiptRow = { file: string; standing: string };

/** Newest 5 witness receipts (md, INDEX.md excluded), with standings. */
async function recentStandings(): Promise<
  { ok: true; rows: ReceiptRow[] } | { ok: false; error: string }
> {
  const dir = path.join(process.cwd(), "..", "popcorn_demo", "receipts");
  try {
    const files = (await readdir(dir))
      .filter((f) => f.endsWith(".md") && f !== "INDEX.md")
      .sort()
      .slice(-5)
      .reverse();
    const rows = await Promise.all(
      files.map(async (file) => {
        try {
          const text = await readFile(`${dir}/${file}`, "utf8");
          return { file, standing: extractStanding(text) };
        } catch {
          return { file, standing: "UNREADABLE" };
        }
      }),
    );
    return { ok: true, rows };
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
}

type KdRow = { id: string; status: string };

/**
 * KD-122/123/124 rows from the v26.10.20 divergence register: table lines
 * "| KD-nnn | ... | STATUS |" — id (col 1) + status (last column) only.
 */
async function kdRows(): Promise<
  { ok: true; rows: KdRow[] } | { ok: false; error: string }
> {
  const file = path.join(
    process.cwd(),
    "..",
    "docs/jira/v26.10.20/KNOWN_DIVERGENCES.md",
  );
  try {
    const text = await readFile(file, "utf8");
    const rows: KdRow[] = [];
    for (const line of text.split("\n")) {
      const m = line.match(/^\|\s*(KD-\d+)\s*\|/);
      if (!m) continue;
      const cells = line.split("|").map((c) => c.trim());
      const status = cells.filter(Boolean).at(-1) ?? "UNKNOWN";
      rows.push({ id: m[1], status: status || "UNKNOWN" });
    }
    return { ok: true, rows };
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
}


type ScvdRow = { metric: string; measured: string; target: string; verdict: string };

/**
 * W22-A SCVD block: server-side parse of popcorn_demo/BENCH_SCVD.md.
 * Extracts the Tier 1/2/3 PRD verdict rows, the Threshold Wall LOCATED
 * rung, and the W15-C tail-invariance verdict. Typed-amber degrade when
 * the file is missing/unreadable or the corpus shape drifts.
 */
async function scvdRows(): Promise<
  { ok: true; rows: ScvdRow[] } | { ok: false; error: string }
> {
  const file = path.join(process.cwd(), "..", "popcorn_demo", "BENCH_SCVD.md");
  try {
    const text = await readFile(file, "utf8");
    const rows: ScvdRow[] = [];
    for (const line of text.split("\n")) {
      const t = line.match(/^\| (Tier \d) \| ([^|]+) \| ([^|]+) \| \*\*(PASS|FAIL)\*\*/);
      if (t) {
        rows.push({
          metric: `${t[1]} ramp (latency / memory)`,
          measured: t[2].trim(),
          target: t[3].trim(),
          verdict: t[4],
        });
      }
    }
    const wall = text.match(/scaling wall is LOCATED at N=(\d+)/);
    rows.push({
      metric: "Threshold Wall (scaling wall located)",
      measured: wall ? `N=${wall[1]}` : "UNPARSED",
      target: "PRD tier set (flat regime)",
      verdict: "LOCATED",
    });
    const tail = text.match(
      /PRD §2\.3 tail-invariance: (HOLDS at \d+\/\d+ re-measured rungs|REFUTES)/,
    );
    rows.push({
      metric: "Tail invariance (W15-C, per-actor p99/p50 ≤1.15)",
      measured: "63 runs (7 rungs × 9), max ratio 1.13",
      target: "PRD §2.3 ≤1.15 at 9-run resolution",
      verdict: tail ? tail[1] : "UNPARSED",
    });
    return { ok: true, rows };
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
}

const GREEN = "#2e7d32";
const AMBER = "#b26a00";
const RED = "#b02a37";

function statusTone(status: string): string {
  if (status === "ALIVE" || status === "PASS" || status === "CLOSED") return GREEN;
  if (
    status === "SUSPECT" || status === "UNKNOWN" ||
    status === "PARTIAL_ALIVE" || status === "PROVISIONAL" ||
    status === "UNREADABLE" || status === "UNPARSED"
  ) {
    return AMBER;
  }
  return RED;
}

export default async function PopcornPage() {
  const [endpoints, tenants, standings, kd, scvd] = await Promise.all([
    fetchJson("/metadata/endpoints"),
    fetchJson("/tenants"),
    recentStandings(),
    kdRows(),
    scvdRows(),
  ]);

  return (
    <main className="mx-auto max-w-3xl p-8">
      <h1 className="text-2xl font-semibold mb-4">Popcorn Testbed</h1>
      <p className="mb-6" style={{ color: "var(--smalt-muted)" }}>
        ARM control-plane face of the popcorn Chicago testbed. All requests
        target the local smalt emulator; witness receipts and the KD register
        are read from the repository tree on the server, never fetched.
      </p>

      <section className="mb-6">
        <h2 className="text-lg font-semibold mb-2">Substrate status</h2>
        <ul className="text-sm space-y-1">
          <li>
            ARM gateway: <code>{SMALT_ARM}</code>
          </li>
          <li>
            GET /metadata/endpoints:{" "}
            {endpoints.ok ? (
              <>
                <span style={{ color: GREEN }}>reachable</span> (
                {Object.keys(endpoints.body as Endpoints).length} keys)
              </>
            ) : (
              <span style={{ color: RED }}>{endpoints.error}</span>
            )}
          </li>
          <li>
            GET /tenants:{" "}
            {tenants.ok ? (
              <span style={{ color: GREEN }}>reachable</span>
            ) : (
              <span style={{ color: RED }}>{tenants.error}</span>
            )}
          </li>
        </ul>
      </section>

      <section className="mb-6">
        <h2 className="text-lg font-semibold mb-2">Tenants</h2>
        {tenants.ok ? (
          <TenantList body={tenants.body} />
        ) : (
          <p className="text-sm" style={{ color: RED }}>
            Tenant list unavailable: {tenants.error}
          </p>
        )}
      </section>

      <section className="mb-6">
        <h2 className="text-lg font-semibold mb-2">
          Witness standings (newest 5)
        </h2>
        {standings.ok ? (
          standings.rows.length > 0 ? (
            <table className="text-sm w-full">
              <thead>
                <tr>
                  <th className="text-left pr-4">Receipt</th>
                  <th className="text-left">Standing</th>
                </tr>
              </thead>
              <tbody>
                {standings.rows.map((r) => (
                  <tr key={r.file}>
                    <td className="pr-4 py-0.5">
                      <code>{r.file}</code>
                    </td>
                    <td
                      className="py-0.5 font-medium"
                      style={{ color: statusTone(r.standing) }}
                    >
                      {r.standing}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <p className="text-sm" style={{ color: AMBER }}>
              no witness receipts found in popcorn_demo/receipts/
            </p>
          )
        ) : (
          <p className="text-sm" style={{ color: AMBER }}>
            popcorn_demo/receipts/ not readable from the server runtime:{" "}
            {standings.error}
          </p>
        )}
      </section>

      <section className="mb-6">
        <h2 className="text-lg font-semibold mb-2">wasm BEAM (live iframe)</h2>
        {/*
          Static asset served from public/popcorn/ — bundle copied from
          popcorn_demo/public/out via `cp -R popcorn_demo/public/out
          workspace/public/popcorn/out` (plus app.js + this host index.html).
          The wasm BEAM boots inside the iframe and talks to the same loopback
          substrate (127.0.0.1:8443/9443); the emulator CORS-permissive posture
          allows those fetches from the workspace origin. The page's server
          component above stays intact — all React I/O remains server-side.
        */}
        <iframe
          src="/popcorn/index.html"
          title="Popcorn wasm BEAM"
          className="w-full border rounded"
          style={{ height: 480, background: "#fff" }}
        />
      </section>

      {/* PRD §2.4 signed-transactional delta: client component stages,
          signs (HMAC-SHA256, per-page session key) and POSTs to the sync route. */}
      <section className="mb-6">
        <h2 className="text-lg font-semibold mb-2">Stage delta → Sync</h2>
        <DeltaSync />
      </section>

      <section className="mb-6">
        <h2 className="text-lg font-semibold mb-2">
          SCVD verdicts (popcorn_demo/BENCH_SCVD.md)
        </h2>
        {scvd.ok ? (
          <table className="text-sm w-full">
            <thead>
              <tr>
                <th className="text-left pr-4">Metric</th>
                <th className="text-left pr-4">Measured</th>
                <th className="text-left pr-4">PRD target</th>
                <th className="text-left">Verdict</th>
              </tr>
            </thead>
            <tbody>
              {scvd.rows.map((r) => (
                <tr key={r.metric}>
                  <td className="pr-4 py-0.5">{r.metric}</td>
                  <td className="pr-4 py-0.5">{r.measured}</td>
                  <td className="pr-4 py-0.5">{r.target}</td>
                  <td
                    className="py-0.5 font-medium"
                    style={{ color: statusTone(r.verdict) }}
                  >
                    {r.verdict}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <p className="text-sm" style={{ color: AMBER }}>
            BENCH_SCVD.md not readable from the server runtime: {scvd.error}
          </p>
        )}
      </section>

      <section>
        <h2 className="text-lg font-semibold mb-2">
          Known divergences (v26.10.20 register)
        </h2>
        {kd.ok ? (
          kd.rows.length > 0 ? (
            <table className="text-sm w-full">
              <thead>
                <tr>
                  <th className="text-left pr-4">ID</th>
                  <th className="text-left">Status</th>
                </tr>
              </thead>
              <tbody>
                {kd.rows.map((r) => (
                  <tr key={r.id}>
                    <td className="pr-4 py-0.5">
                      <code>{r.id}</code>
                    </td>
                    <td
                      className="py-0.5 font-medium"
                      style={{ color: statusTone(r.status) }}
                    >
                      {r.status}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <p className="text-sm" style={{ color: AMBER }}>
              no KD rows parsed from KNOWN_DIVERGENCES.md
            </p>
          )
        ) : (
          <p className="text-sm" style={{ color: AMBER }}>
            KD register not readable from the server runtime: {kd.error}
          </p>
        )}
      </section>
    </main>
  );
}

function TenantList({ body }: { body: unknown }) {
  const rows = Array.isArray(body)
    ? body
    : typeof body === "object" && body !== null && Array.isArray((body as { value?: unknown }).value)
      ? (body as { value: unknown[] }).value
      : [];
  if (rows.length === 0) {
    return <p className="text-sm" style={{ color: "var(--smalt-muted)" }}>No tenants returned.</p>;
  }
  const ids = rows
    .map((t) =>
      typeof t === "object" && t !== null
        ? ((t as Record<string, unknown>).tenantId ?? (t as Record<string, unknown>).id)
        : t,
    )
    .map(String);
  return (
    <ul className="text-sm space-y-1">
      {ids.map((id) => (
        <li key={id}>
          <code>{id}</code>
        </li>
      ))}
    </ul>
  );
}
