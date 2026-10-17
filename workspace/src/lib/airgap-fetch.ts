/**
 * Server-side air-gap fetch wrapper (Next.js server / route-handler layer).
 *
 * The client-side guard lives in lib/smalt.ts (smaltFetch + assertLocalUrl);
 * this module is the SERVER complement: it wraps globalThis.fetch so that any
 * server-side fetch (route handlers, server actions, server components) can
 * only reach the loopback smalt emulator on its three wire ports:
 *
 *   9443 ARM control plane · 9444 TLS twin · 8443 data-plane egress
 *
 * A fetch to any other host/port — including *.azure.com / *.microsoft.com —
 * is aborted before connect and surfaces as a typed AirGapViolation, with an
 * audit row recorded (drainAirGapAudit). Chicago-school: real fetch, real
 * loopback server in tests — no mocks.
 */

export const AIRGAP_ALLOWED_PORTS = new Set(["9443", "9444", "8443"]);

const AIRGAP_ALLOWED_HOSTS = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);

/** Typed air-gap refusal — thrown instead of performing the outbound fetch. */
export class AirGapViolation extends Error {
  readonly name = "AirGapViolation";
  readonly host: string;
  readonly port: string;
  readonly url: string;

  constructor(url: string, host: string, port: string) {
    super(
      `AirGapViolation: refused fetch to ${host}:${port} — only loopback smalt endpoints (127.0.0.1/localhost/::1 on 9443/9444/8443) are reachable from the server layer.`,
    );
    this.host = host;
    this.port = port;
    this.url = url;
  }
}

export interface AirGapAuditRow {
  readonly ts: string;
  readonly url: string;
  readonly host: string;
  readonly port: string;
  readonly violation: "non-loopback-host" | "disallowed-port";
}

/** In-module audit ledger (server memory). Drain + persist externally if needed. */
let audit: AirGapAuditRow[] = [];

export function drainAirGapAudit(): AirGapAuditRow[] {
  const rows = audit;
  audit = [];
  return rows;
}

function record(row: AirGapAuditRow) {
  audit.push(row);
}

let installed = false;

/**
 * Wrap globalThis.fetch with destination allowlisting. Idempotent: repeated
 * installAirGapFetch() calls are no-ops (the wrapper is installed once).
 */
export function installAirGapFetch(): void {
  if (installed) return;
  installed = true;
  const inner = globalThis.fetch.bind(globalThis);
  globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
    const raw = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    let u: URL;
    try {
      u = new URL(raw);
    } catch {
      throw new AirGapViolation(String(raw), "(unparseable)", "-");
    }
    const host = u.hostname;
    const port = u.port || (u.protocol === "https:" ? "443" : "80");
    if (!AIRGAP_ALLOWED_HOSTS.has(host)) {
      record({ ts: new Date().toISOString(), url: u.href, host, port, violation: "non-loopback-host" });
      throw new AirGapViolation(u.href, host, port);
    }
    if (!AIRGAP_ALLOWED_PORTS.has(port)) {
      record({ ts: new Date().toISOString(), url: u.href, host, port, violation: "disallowed-port" });
      throw new AirGapViolation(u.href, host, port);
    }
    // redirect:"error" by default — a 30x with an off-host Location must not
    // carry the request past the air-gap guard (same law as lib/smalt.ts).
    return inner(u, { redirect: "error", ...init });
  }) as typeof fetch;
}
