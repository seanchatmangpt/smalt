/**
 * SmaltTokenCredential - a @azure/core-auth TokenCredential that mints ARM
 * bearer tokens from smalt's STS token endpoint (client_credentials grant).
 *
 * Why a custom credential: @azure/identity's ClientSecretCredential cannot be
 * used against the smalt emulator - msal-node resolves tenant endpoints via
 * OIDC instance discovery before posting the client_credentials grant, and the
 * emulator does not serve the discovery envelope, so msal-node fails with
 * `endpoints_resolution_error` before the token POST is ever sent.
 * Witnessed in docs/jira/v26.10.14/sdk-results/ts-arm-resources.md
 * (Bootstrapping constraint 1). The raw STS POST works: 200 + 3-segment JWT.
 *
 * Real-Azure delta: real Azure serves the discovery envelope at
 * `{authority}/{tenant}/...`, so ClientSecretCredential works there. Swap this
 * credential for `new ClientSecretCredential(...)` when pointing at real Azure.
 */
import type { TokenCredential, AccessToken, GetTokenOptions } from "@azure/core-auth";

export interface SmaltCredentialOptions {
  /** ARM plane base URL, e.g. https://localhost:9443. */
  armBase: string;
  /** STS issuer tenant. The emulator accepts any tenant string. */
  tenant?: string;
  /** Client id/secret - the emulator accepts arbitrary credentials. */
  clientId?: string;
  clientSecret?: string;
  /** Refresh the cached token this many ms before expiry (default 60_000). */
  refreshSlackMs?: number;
  /** Fetch override (tests only). */
  fetchImpl?: typeof fetch;
}

export class SmaltTokenCredential implements TokenCredential {
  private readonly armBase: string;
  private readonly tenant: string;
  private readonly clientId: string;
  private readonly clientSecret: string;
  private readonly refreshSlackMs: number;
  private readonly fetchImpl: typeof fetch;
  private cached: AccessToken | null = null;
  private inflight: Promise<AccessToken> | null = null;
  private mintCounter = 0;

  constructor(options: SmaltCredentialOptions) {
    if (!options?.armBase) throw new Error("SmaltTokenCredential: armBase is required");
    this.armBase = options.armBase.replace(/\/+$/, "");
    this.tenant = options.tenant ?? "smalt-tenant";
    this.clientId = options.clientId ?? "workspace-console";
    this.clientSecret = options.clientSecret ?? "workspace-secret";
    this.refreshSlackMs = options.refreshSlackMs ?? 60_000;
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  async getToken(
    scopes: string | string[],
    _options?: GetTokenOptions,
  ): Promise<AccessToken> {
    const scope = Array.isArray(scopes) ? scopes[0] : scopes;
    if (!scope) throw new Error("SmaltTokenCredential.getToken: scopes is required");
    const now = Date.now();
    if (this.cached && this.cached.expiresOnTimestamp - this.refreshSlackMs > now) {
      return this.cached;
    }
    if (this.inflight) return this.inflight;
    this.inflight = this.mint(scope)
      .then((t) => {
        this.cached = t;
        this.inflight = null;
        return t;
      })
      .catch((e) => {
        this.inflight = null;
        throw e;
      });
    return this.inflight;
  }

  /**
   * Forced mint bypassing the cache. The probe uses this to witness a real STS
   * round-trip on every run.
   */
  async mintFresh(scope: string): Promise<AccessToken> {
    const token = await this.mint(scope);
    this.cached = token;
    return token;
  }

  /** STS POSTs performed so far (cache misses). Diagnostic only. */
  get mintCount(): number {
    return this.mintCounter;
  }

  private async mint(scope: string): Promise<AccessToken> {
    this.mintCounter++;
    const body = new URLSearchParams({
      grant_type: "client_credentials",
      client_id: this.clientId,
      client_secret: this.clientSecret,
      scope,
    });
    const res = await this.fetchImpl(`${this.armBase}/${this.tenant}/oauth2/v2.0/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`STS mint failed: status=${res.status} body=${text.slice(0, 400)}`);
    }
    const json = (await res.json()) as { access_token?: unknown; expires_in?: unknown };
    if (typeof json.access_token !== "string" || json.access_token.split(".").length !== 3) {
      throw new Error("STS mint failed: access_token missing or not a 3-segment JWT");
    }
    const expiresInMs = Number(json.expires_in ?? 3600) * 1000;
    return { token: json.access_token, expiresOnTimestamp: Date.now() + expiresInMs };
  }
}
