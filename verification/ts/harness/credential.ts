// credential.ts — credential factory: smalt (custom TokenCredential POSTing
// the substrate STS) default, azure (official ClientSecretCredential) switch.
// The azure leg loud-SKIPs (exit 3) if the identity probe shows the
// KD-100 instance-discovery failure — never a fake pass.
import { randomUUID } from "node:crypto";
import type { TokenCredential, GetTokenOptions, AccessToken } from "@azure/core-auth";

export const TENANT = "00000000-0000-0000-0000-000000000000";
export const CLIENT = "00000000-0000-0000-0000-000000000000";
export const SECRET = "smalt-tf-mock-secret";
// Non-zero GUID: @azure SDKs validate subscription ids client-side and
// reject the all-zero default; the substrate admits any subscription id.
export const SUB = "11111111-1111-1111-1111-111111111111";

export interface SubstrateCoords {
  arm: string; // http://127.0.0.1:<port>
  tls: string; // https://localhost:<tls-twin>
  egress: string; // https or http data-plane base
  amqpPort: number;
  ehPort: number;
}

export class SmaltTokenCredential implements TokenCredential {
  private cached: AccessToken | null = null;
  private stsUrl: string;
  private scope: string;
  constructor(stsUrl: string, scope = "https://management.azure.com/.default") {
    this.stsUrl = stsUrl;
    this.scope = scope;
  }
  async getToken(
    _scopes: string | string[],
    _options?: GetTokenOptions,
  ): Promise<AccessToken> {
    if (this.cached && this.cached.expiresOnTimestamp > Date.now() + 60_000) {
      return this.cached;
    }
    const res = await fetch(this.stsUrl, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "client_credentials",
        client_id: CLIENT,
        client_secret: SECRET,
        scope: this.scope,
      }),
    });
    if (!res.ok) {
      throw new Error(`smalt STS ${res.status}: ${(await res.text()).slice(0, 200)}`);
    }
    const payload = (await res.json()) as { access_token: string };
    const mid = payload.access_token.split(".")[1];
    const claims = JSON.parse(Buffer.from(mid, "base64url").toString("utf8"));
    this.cached = {
      token: payload.access_token,
      expiresOnTimestamp: (claims.exp ?? 0) * 1000,
    };
    return this.cached;
  }
}

export type CredMode = "smalt" | "azure";

export async function makeCredential(
  mode: CredMode,
  tls: string,
): Promise<TokenCredential> {
  if (mode === "smalt") {
    return new SmaltTokenCredential(`${tls}/${TENANT}/oauth2/v2.0/token`);
  }
  const { ClientSecretCredential } = await import("@azure/identity");
  const cred = new ClientSecretCredential(TENANT, CLIENT, SECRET, {
    authorityHost: tls,
  });
  // Identity probe: instance discovery (KD-100). Fail loud, not fake-pass.
  try {
    await cred.getToken("https://management.azure.com/.default", {
      requestId: randomUUID(),
    });
  } catch (err: any) {
    const msg = String(err?.message ?? "");
    if (/instance|discovery|metadata|endpoints_resolution|ENOTFOUND|ENOENT|fetch failed/i.test(msg)) {
      const e = new Error(
        `LOUD-SKIP: azure credential leg failed on KD-100 instance-discovery: ${msg.slice(0, 200)}`,
      );
      (e as any).skipCode = 3;
      throw e;
    }
    throw err;
  }
  return cred;
}
