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
import { assertLocalUrl } from "../smalt.js"; // SHIM-COURT: air-gap host check on armBase

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
  private cached: Map<string, AccessToken> = new Map();
  private inflight: Map<string, Promise<AccessToken>> = new Map();
  private mintCounter = 0;

  constructor(options: SmaltCredentialOptions) {
    if (!options?.armBase) throw new Error("SmaltTokenCredential: armBase is required");
    this.armBase = options.armBase.replace(/\/+$/, "");
    // SHIM-COURT: refuse non-local armBase at construction — the only egress
    // this credential can ever make is the STS POST against armBase.
    assertLocalUrl(this.armBase);
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
    // R23 fix: cache and inflight are keyed by scope — a concurrent
    // different-scope call must not inherit another scope's token.
    const cached = this.cached.get(scope);
    if (cached && cached.expiresOnTimestamp - this.refreshSlackMs > now) {
      return cached;
    }
    const inflight = this.inflight.get(scope);
    if (inflight) return inflight;
    const mintPromise = this.mint(scope)
      .then((t) => {
        this.cached.set(scope, t);
        this.inflight.delete(scope);
        return t;
      })
      .catch((e) => {
        this.inflight.delete(scope);
        throw e;
      });
    this.inflight.set(scope, mintPromise);
    return mintPromise;
  }

  /**
   * Forced mint bypassing the cache. The probe uses this to witness a real STS
   * round-trip on every run.
   */
  async mintFresh(scope: string): Promise<AccessToken> {
    const token = await this.mint(scope);
    this.cached.set(scope, token);
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
      // SHIM-COURT: redirect:"error" — the client_secret body must never
      // follow an off-host 30x Location past the air-gap guard.
      redirect: "error",
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
