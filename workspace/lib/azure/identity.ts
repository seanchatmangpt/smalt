/**
 * STS identity client for the smalt emulator — console lane (v26.10.16).
 *
 * Implements the Azure AD client_credentials flow against smalt's STS
 * (`POST /{tenant}/oauth2/v2.0/token`), plus the OIDC discovery surfaces the
 * emulator serves (/.well-known/openid-configuration, /metadata/endpoints,
 * /common/discovery/instance, /{tid}/discovery/v2.0/keys) and ARM tenant
 * enumeration. All network I/O rides smaltFetch (air-gap guard).
 *
 * Signature validation, honestly: smalt's STS signs HS256 with a shared
 * secret it does NOT publish — the JWKS endpoint serves `{"keys":[]}` by
 * design. So this client never verifies signatures locally. Instead it does
 * (a) local claims inspection (aud/iss/roles/appid/oid/sub/tid/exp-nbf
 * window rendering) and (b) STS-verified acceptance: a token is "valid" iff
 * the substrate accepts it on a protected route (401 otherwise). The
 * substrate is the verifier; the client trusts only what the substrate lets
 * through.
 *
 * Real-Azure delta: real Azure publishes RS256 JWKS, so local cryptographic
 * validation is possible there. Swap in a JWKS-verifying validator (or
 * @azure/identity) when pointing at real Azure.
 */
import { smaltFetch } from "../smalt.js";

/** Fetch-like bound to pre-resolved path strings (smaltFetch seam). */
export type FetchLike = (path: string, init?: RequestInit) => Promise<Response>;

export const SMALT_ARM_RESOURCE = "https://management.azure.com";

export interface MintOptions {
  /** Client id (emulator accepts arbitrary values). */
  clientId?: string;
  /** Client secret (emulator accepts arbitrary values). */
  clientSecret?: string;
  /** Issuer tenant (emulator accepts any tenant string). */
  tenant?: string;
  /** Scope/resource; default https://management.azure.com/.default. */
  scope?: string;
}

export interface MintedToken {
  accessToken: string;
  tokenType: string;
  expiresInSec: number;
  /** Claims decoded from the access token payload. */
  claims: Record<string, unknown>;
}

/** Base64url-decode a JWT segment. */
export function b64urlDecode(seg: string): string {
  const pad = seg.length % 4 === 0 ? "" : "=".repeat(4 - (seg.length % 4));
  return Buffer.from(seg.replace(/-/g, "+").replace(/_/g, "/") + pad, "base64").toString("utf8");
}

/** Decode a JWT into header + payload without validating anything. */
export function decodeJwt(
  token: string,
): { header: Record<string, unknown>; payload: Record<string, unknown> } {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error(`not a 3-segment JWT (${parts.length} segments)`);
  return {
    header: JSON.parse(b64urlDecode(parts[0])),
    payload: JSON.parse(b64urlDecode(parts[1])),
  };
}

export interface ClaimsInspection {
  claims: Record<string, unknown>;
  aud: unknown;
  iss: unknown;
  appid: unknown;
  oid: unknown;
  sub: unknown;
  tid: unknown;
  roles: string[];
  /** Seconds since epoch. */
  exp: number | null;
  nbf: number | null;
  iat: number | null;
  /** Validity window. */
  window: {
    /** True iff now (or `nowSec`) falls inside [nbf, exp). */
    isValidNow: boolean;
    isExpired: boolean;
    notYetValid: boolean;
    /** ms until expiry (negative when expired). */
    msUntilExpiry: number;
    /** ISO render of the window for console display. */
    rendered: string;
  };
}

/** Local claims inspection — no cryptographic verification (see module doc). */
export function inspectClaims(
  token: string,
  nowSec = Math.floor(Date.now() / 1000),
): ClaimsInspection {
  const { payload } = decodeJwt(token);
  const num = (v: unknown): number | null => (typeof v === "number" ? v : null);
  const exp = num(payload.exp);
  const nbf = num(payload.nbf);
  const iat = num(payload.iat);
  const roles = Array.isArray(payload.roles) ? payload.roles.map(String) : [];
  const isExpired = exp !== null && nowSec >= exp;
  const notYetValid = nbf !== null && nowSec < nbf;
  const iso = (s: number | null) => (s === null ? "n/a" : new Date(s * 1000).toISOString());
  return {
    claims: payload,
    aud: payload.aud,
    iss: payload.iss,
    appid: payload.appid,
    oid: payload.oid,
    sub: payload.sub,
    tid: payload.tid,
    roles,
    exp,
    nbf,
    iat,
    window: {
      isValidNow: !isExpired && !notYetValid,
      isExpired,
      notYetValid,
      msUntilExpiry: exp === null ? Number.POSITIVE_INFINITY : exp * 1000 - nowSec * 1000,
      rendered: nbf !== null ? `${iso(nbf)} → ${iso(exp)}` : `${iso(iat)} → ${iso(exp)}`,
    },
  };
}

export interface Challenge {
  scheme: string;
  params: Record<string, string>;
}

/** Parse a WWW-Authenticate challenge header into scheme + params. */
export function parseWwwAuthenticate(header: string): Challenge {
  const m = header.match(/^\s*([\w-]+)\s+(.*)$/);
  if (!m) return { scheme: header.trim(), params: {} };
  const params: Record<string, string> = {};
  const re = /([\w-]+)="((?:[^"\\]|\\.)*)"/g;
  let pm: RegExpExecArray | null;
  while ((pm = re.exec(m[2])) !== null) {
    params[pm[1]] = pm[2].replace(/\\"/g, '"');
  }
  return { scheme: m[1], params };
}

/** Default fetch binding: smaltFetch against the configured armBase. */
function defaultFetch(armBase: string, fetchImpl?: FetchLike): FetchLike {
  if (fetchImpl) return fetchImpl;
  return (path, init) => smaltFetch(armBase, path, init);
}

export interface StsClientOptions {
  /** ARM plane base, e.g. http://127.0.0.1:9443 (air-gap enforced). */
  armBase: string;
  tenant?: string;
  clientId?: string;
  clientSecret?: string;
  scope?: string;
  /** Fetch override (tests only). */
  fetchImpl?: FetchLike;
}

export class StsClient {
  private readonly armBase: string;
  private readonly tenant: string;
  private readonly clientId: string;
  private readonly clientSecret: string;
  private readonly scope: string;
  private readonly fetchImpl: FetchLike;

  constructor(options: StsClientOptions) {
    if (!options?.armBase) throw new Error("StsClient: armBase is required");
    this.armBase = options.armBase.replace(/\/+$/, "");
    this.tenant = options.tenant ?? "smalt-tenant";
    this.clientId = options.clientId ?? "workspace-console";
    this.clientSecret = options.clientSecret ?? "workspace-secret";
    this.scope = options.scope ?? `${SMALT_ARM_RESOURCE}/.default`;
    this.fetchImpl = defaultFetch(this.armBase, options.fetchImpl);
  }

  /** Mint a token via the client_credentials grant. */
  async mint(opts: MintOptions = {}): Promise<MintedToken> {
    const body = new URLSearchParams({
      grant_type: "client_credentials",
      client_id: opts.clientId ?? this.clientId,
      client_secret: opts.clientSecret ?? this.clientSecret,
      scope: opts.scope ?? this.scope,
    });
    const res = await this.fetchImpl(`/${this.tenant}/oauth2/v2.0/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body,
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`STS token POST failed: ${res.status} ${text.slice(0, 200)}`);
    }
    const json = (await res.json()) as {
      access_token: string;
      token_type: string;
      expires_in: number;
    };
    return {
      accessToken: json.access_token,
      tokenType: json.token_type,
      expiresInSec: json.expires_in,
      claims: decodeJwt(json.access_token).payload,
    };
  }

  /**
   * STS-verified acceptance: the token is valid iff the substrate accepts it
   * on a protected route (the STS validates the bearer on every request).
   * 200 → accepted; 401 → refused; anything else throws.
   */
  async verifyViaSts(
    token: string,
    path = "/subscriptions?api-version=2022-09-01",
  ): Promise<{ accepted: boolean; status: number }> {
    const res = await this.fetchImpl(path, {
      method: "GET",
      headers: { authorization: `Bearer ${token}` },
    });
    if (res.status === 200) return { accepted: true, status: 200 };
    if (res.status === 401) return { accepted: false, status: 401 };
    throw new Error(`unexpected protected-route status ${res.status}`);
  }

  /** Root OIDC discovery document. */
  async openidConfigurationRoot(): Promise<Record<string, unknown>> {
    const res = await this.fetchImpl("/.well-known/openid-configuration");
    if (!res.ok) throw new Error(`openid-configuration (root): ${res.status}`);
    return res.json();
  }

  /** AAD instance discovery envelope (2022-09-01). */
  async instanceDiscovery(): Promise<Record<string, unknown>> {
    const res = await this.fetchImpl("/common/discovery/instance?api-version=2022-09-01");
    if (!res.ok) throw new Error(`discovery/instance: ${res.status}`);
    return res.json();
  }

  /** Full /metadata/endpoints envelope (authority echo). */
  async metadataEndpoints(): Promise<Record<string, unknown>> {
    const res = await this.fetchImpl("/metadata/endpoints");
    if (!res.ok) throw new Error(`metadata/endpoints: ${res.status}`);
    return res.json();
  }

  /**
   * The tenant JWKS. HONESTLY EMPTY for smalt: HS256 uses a shared secret
   * the STS does not publish, so this returns `{"keys":[]}` — local
   * signature validation is impossible by design; validation is delegated
   * to the STS (see verifyViaSts).
   */
  async jwks(tenant = this.tenant, token?: string): Promise<{ keys: unknown[] }> {
    // The emulator gates discovery/keys behind the bearer (witnessed 401
    // tokenless); send a freshly minted token when none is supplied.
    const bearer = token ? token : (await this.mint()).accessToken;
    const res = await this.fetchImpl(`/${tenant}/discovery/v2.0/keys`, {
      headers: { authorization: `Bearer ${bearer}` },
    });
    if (!res.ok) throw new Error(`discovery/keys: ${res.status}`);
    return res.json();
  }

  /** Enumerate ARM tenants. */
  async listTenants(): Promise<Array<Record<string, unknown>>> {
    const res = await this.fetchImpl("/tenants?api-version=2022-09-01");
    if (!res.ok) throw new Error(`tenants: ${res.status}`);
    const json = (await res.json()) as { value: Array<Record<string, unknown>> };
    return json.value;
  }

  /**
   * Challenge-response helper: issue the request tokenless, parse the 401
   * WWW-Authenticate challenge, mint, then retry with the bearer. Returns
   * the retried response (status + parsed JSON body).
   */
  async withChallenge<T = unknown>(
    path: string,
    opts: { method?: string; mintOverrides?: MintOptions } = {},
  ): Promise<{ status: number; challenge: Challenge; body: T }> {
    const first = await this.fetchImpl(path, { method: opts.method ?? "GET" });
    if (first.status !== 401) {
      const body = (await first.json().catch(() => null)) as T | null;
      return { status: first.status, challenge: { scheme: "", params: {} }, body: body as T };
    }
    const challenge = parseWwwAuthenticate(first.headers.get("www-authenticate") ?? "");
    const minted = await this.mint(opts.mintOverrides);
    const retry = await this.fetchImpl(path, {
      method: opts.method ?? "GET",
      headers: { authorization: `Bearer ${minted.accessToken}` },
    });
    return { status: retry.status, challenge, body: (await retry.json()) as T };
  }
}

export interface RefreshWindowOptions {
  /** Refresh this many ms before exp (default 60_000). */
  slackMs?: number;
  /** Clock override for tests. */
  nowMs?: () => number;
}

/**
 * Token expiry clock with proactive refresh window: `needsRefresh` flips
 * true `slackMs` before exp so callers mint proactively, never riding an
 * expired token to a 401.
 */
export class TokenClock {
  private readonly slackMs: number;
  private readonly nowMs: () => number;
  private inspection: ClaimsInspection;

  constructor(token: string, options: RefreshWindowOptions = {}) {
    this.slackMs = options.slackMs ?? 60_000;
    this.nowMs = options.nowMs ?? Date.now;
    this.inspection = inspectClaims(token, Math.floor(this.nowMs() / 1000));
  }

  /** Re-inspect against the current (possibly overridden) clock. */
  refresh(token: string): void {
    this.inspection = inspectClaims(token, Math.floor(this.nowMs() / 1000));
  }

  get claims(): Record<string, unknown> {
    return this.inspection.claims;
  }

  get msUntilExpiry(): number {
    return this.inspection.exp === null
      ? Number.POSITIVE_INFINITY
      : this.inspection.exp * 1000 - this.nowMs();
  }

  get isExpired(): boolean {
    return this.msUntilExpiry <= 0;
  }

  /** True within `slackMs` of exp — mint a fresh token now. */
  get needsRefresh(): boolean {
    return this.msUntilExpiry <= this.slackMs;
  }
}
