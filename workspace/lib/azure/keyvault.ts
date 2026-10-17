/**
 * Smalt Key Vault console client — secrets CRUD + versioning, key crypto,
 * challenge-response auth handshake, ARM vault + secret provisioning.
 *
 * Wire surface (lib/smalt/egress_router.ex + arm_gateway/router.ex):
 *   POST /keys/:name/create            — key create (kty RSA/oct), version accumulate
 *   GET  /keys, /keys/:name, /keys/:name/versions, /keys/:name/:version
 *   POST /keys/:name/{encrypt,decrypt,sign,verify,wrapKey,unwrapKey}
 *   PUT  /secrets/:name                — set secret (re-PUT = new version id)
 *   GET  /secrets/:name                — typed 404 SecretNotFound envelope
 *   GET  /secrets, DELETE /secrets/:name
 *   401 challenge (mode-blind kv_challenge_guard): WWW-Authenticate carries
 *     `authorization="<sts-authority>"` — we mint an STS bearer and retry once.
 *   ARM PUT .../Microsoft.KeyVault/vaults/:v (and /secrets/:s children) cross-plane
 *     seeds the 8443 data-plane store.
 *
 * Real-Azure delta: real vaults live at https://{vault}.vault.azure.net with
 * AAD authority login.microsoftonline.com; smalt collapses control+data into
 * loopback ports. Only the base URLs differ — the wire envelopes match.
 */
import { assertLocalUrl, SMALT_ARM, SMALT_EGRESS } from "../smalt.js"; // SHIM-COURT: air-gap host guard

export const KV_API_VERSION = "7.4";
export const ARM_API_VERSION = "2022-07-01";

/** Typed error envelope for KV refusals ({"error":{code,message}}). */
export class KvError extends Error {
  readonly code: string;
  readonly status: number;
  constructor(code: string, message: string, status: number) {
    super(`keyvault: ${code}: ${message} (HTTP ${status})`);
    this.name = "KvError";
    this.code = code;
    this.status = status;
  }
}

export interface KvKeyAttributes {
  enabled?: boolean;
  created?: number;
  updated?: number;
  expires?: number;
}

export interface KvKey {
  kid: string;
  kty: string;
  keyOps?: string[];
  n?: string;
  e?: string;
  attributes: KvKeyAttributes;
}

export interface KvSecret {
  value?: string;
  id: string;
  contentType?: string;
  attributes: KvKeyAttributes & { expires?: number };
}

export interface SetSecretOptions {
  enabled?: boolean;
  /** POSIX seconds — expiration attribute. */
  expires?: number;
  contentType?: string;
}

export interface SmaltKeyVaultClientOptions {
  /** Data plane (crypto+secrets) base, e.g. http://127.0.0.1:8443. */
  dataBase?: string;
  /** ARM plane (STS + provisioning) base, e.g. https://127.0.0.1:9443. */
  armBase?: string;
  tenant?: string;
  clientId?: string;
  clientSecret?: string;
  fetchImpl?: typeof fetch;
}

interface TokenState {
  token: string;
  expiresAtMs: number;
}

/** Parse `WWW-Authenticate: Bearer authorization="...", resource="..."`. */
export function parseChallenge(header: string | null | undefined): {
  authorization?: string;
  resource?: string;
} {
  if (!header) return {};
  const out: { authorization?: string; resource?: string } = {};
  for (const m of header.matchAll(/(\w+)="([^"]*)"/g)) {
    if (m[1] === "authorization") out.authorization = m[2];
    if (m[1] === "resource") out.resource = m[2];
  }
  return out;
}

export class SmaltKeyVaultClient {
  private readonly dataBase: string;
  private readonly armBase: string;
  private readonly tenant: string;
  private readonly clientId: string;
  private readonly clientSecret: string;
  private readonly fetchImpl: typeof fetch;
  private token: TokenState | null = null;

  constructor(options: SmaltKeyVaultClientOptions = {}) {
    this.dataBase = (options.dataBase ?? SMALT_EGRESS).replace(/\/+$/, "");
    this.armBase = (options.armBase ?? SMALT_ARM).replace(/\/+$/, "");
    this.tenant = options.tenant ?? "smalt-tenant";
    this.clientId = options.clientId ?? "workspace-console";
    this.clientSecret = options.clientSecret ?? "workspace-secret";
    this.fetchImpl = options.fetchImpl ?? fetch;
    // SHIM-COURT: both bases pass the air-gap host check at construction.
    assertLocalUrl(this.dataBase);
    assertLocalUrl(this.armBase);
  }

  // -- auth: challenge-response handshake -----------------------------------

  /** Mint an STS bearer (client_credentials) from the challenge authority. */
  async mintToken(authority: string): Promise<TokenState> {
    const res = await this.fetchImpl(
      airFetch(`${authority.replace(/\/+$/, "")}/oauth2/v2.0/token`),
      {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "client_credentials",
          client_id: this.clientId,
          client_secret: this.clientSecret,
          scope: "https://vault.azure.net/.default",
        }).toString(),
      },
    );
    if (!res.ok) {
      throw new KvError(
        "AuthenticationFailed",
        `STS token mint failed with HTTP ${res.status}`,
        res.status,
      );
    }
    const body = (await res.json()) as { access_token?: string; expires_in?: number };
    if (!body.access_token) {
      throw new KvError("AuthenticationFailed", "STS returned no access_token", res.status);
    }
    return {
      token: body.access_token,
      expiresAtMs: Date.now() + (body.expires_in ?? 3600) * 1000 - 60_000,
    };
  }

  private async ensureToken(authority: string): Promise<string> {
    if (this.token && Date.now() < this.token.expiresAtMs) return this.token.token;
    this.token = await this.mintToken(authority);
    return this.token.token;
  }

  private async request(path: string, init: RequestInit = {}): Promise<Response> {
    const headers: Record<string, string> = {
      ...(init.headers as Record<string, string> | undefined),
    };
    let attempted = false;
    for (let attempt = 0; attempt < 2; attempt++) {
      if (this.token) headers["authorization"] = `Bearer ${this.token.token}`;
      const res = await this.fetchImpl(
        airFetch(new URL(path, this.dataBase).toString()),
        { ...init, headers },
      );
      if (res.status !== 401) return res;
      // Mode-blind kv_challenge_guard: tokenless /keys|/secrets first touch
      // 401s with the enriched challenge. Parse `authorization=`, mint, retry.
      const challenge = parseChallenge(res.headers.get("www-authenticate"));
      if (!challenge.authorization || attempted) return res;
      attempted = true;
      await this.ensureToken(challenge.authorization);
    }
    throw new KvError("AuthenticationFailed", "challenge handshake did not converge", 401);
  }

  private static async unwrap<T = Record<string, unknown>>(res: Response): Promise<T> {
    const text = await res.text();
    let body: Record<string, unknown> = {};
    if (text) {
      try {
        body = JSON.parse(text) as Record<string, unknown>;
      } catch {
        body = {};
      }
    }
    if (!res.ok) {
      const err = body["error"] as { code?: string; message?: string } | undefined;
      throw new KvError(err?.code ?? "HttpError", err?.message ?? text, res.status);
    }
    return body as T;
  }

  // -- keys ------------------------------------------------------------------

  async createKey(name: string, opts: { kty?: string } = {}): Promise<KvKey> {
    const res = await this.request(`/keys/${encodeURIComponent(name)}/create`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ kty: opts.kty ?? "RSA-HSM" }),
    });
    return flattenKey(await SmaltKeyVaultClient.unwrap<Record<string, unknown>>(res));
  }

  async getKey(name: string, version?: string): Promise<KvKey> {
    const path = version ? `/keys/${name}/${version}` : `/keys/${name}`;
    return flattenKey(
      await SmaltKeyVaultClient.unwrap<Record<string, unknown>>(
        await this.request(path, { method: "GET" }),
      ),
    );
  }

  async listKeys(): Promise<KvKey[]> {
    const body = await SmaltKeyVaultClient.unwrap<{ value: KvKey[] }>(
      await this.request("/keys", { method: "GET" }),
    );
    return body.value ?? [];
  }

  async listKeyVersions(name: string): Promise<KvKey[]> {
    const body = await SmaltKeyVaultClient.unwrap<{ value?: KvKey[] }>(
      await this.request(`/keys/${encodeURIComponent(name)}/versions`, { method: "GET" }),
    );
    return body.value ?? [];
  }

  // -- crypto ----------------------------------------------------------------

  private async cryptoOp<T>(
    name: string,
    action: string,
    params: Record<string, unknown>,
    version?: string,
  ): Promise<T> {
    const seg = version ? `${encodeURIComponent(name)}/${version}` : encodeURIComponent(name);
    return SmaltKeyVaultClient.unwrap<T>(
      await this.request(`/keys/${seg}/${action}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(params),
      }),
    );
  }

  /** RSA-OAEP-256 encrypt (RSA keys) / A256GCM (oct keys). */
  async encrypt(name: string, plaintext: Uint8Array, version?: string): Promise<Uint8Array> {
    const key = await this.getKey(name);
    const alg = key.kty.startsWith("oct") ? "A256GCM" : "RSA-OAEP-256";
    const out = await this.cryptoOp<{ value: string; iv?: string }>(
      name,
      "encrypt",
      { alg, value: Buffer.from(plaintext).toString("base64") },
      version,
    );
    if (out["iv"] !== undefined) {
      throw new KvError(
        "UnsupportedAlgorithm",
        "AES-GCM returns iv/tag alongside value; use decryptSecretBox for oct keys",
        400,
      );
    }
    return new Uint8Array(Buffer.from(out.value, "base64"));
  }

  async decrypt(name: string, ciphertext: Uint8Array, version?: string): Promise<Uint8Array> {
    const out = await this.cryptoOp<{ value: string }>(
      name,
      "decrypt",
      { alg: "RSA-OAEP-256", value: Buffer.from(ciphertext).toString("base64") },
      version,
    );
    return new Uint8Array(Buffer.from(out.value, "base64"));
  }

  /** Wrap a CEK: RSA-OAEP-256 for RSA keys, A256GCM for oct keys. */
  async wrapKey(name: string, cek: Uint8Array, version?: string): Promise<Uint8Array> {
    const key = await this.getKey(name);
    const alg = key.kty.startsWith("oct") ? "A256GCM" : "RSA-OAEP-256";
    const out = await this.cryptoOp<{ value: string }>(
      name,
      "wrapKey",
      { alg, value: Buffer.from(cek).toString("base64") },
      version,
    );
    return new Uint8Array(Buffer.from(out.value, "base64"));
  }

  async unwrapKey(name: string, wrapped: Uint8Array, version?: string): Promise<Uint8Array> {
    const key = await this.getKey(name);
    const alg = key.kty.startsWith("oct") ? "A256GCM" : "RSA-OAEP-256";
    const out = await this.cryptoOp<{ value: string }>(
      name,
      "unwrapKey",
      { alg, value: Buffer.from(wrapped).toString("base64") },
      version,
    );
    return new Uint8Array(Buffer.from(out.value, "base64"));
  }

  /** RS256 sign of SHA-256(data). Returns the base64url signature. */
  async sign(name: string, data: Uint8Array): Promise<string> {
    const digest = Buffer.from(await crypto.subtle.digest("SHA-256", Buffer.from(data)));
    const out = await this.cryptoOp<{ value: string }>(name, "sign", {
      alg: "RS256",
      digest: digest.toString("base64url"),
    });
    return out.value;
  }

  async verify(name: string, data: Uint8Array, signatureB64Url: string): Promise<boolean> {
    const digest = Buffer.from(await crypto.subtle.digest("SHA-256", Buffer.from(data)));
    const out = await this.cryptoOp<{ value: boolean }>(name, "verify", {
      alg: "RS256",
      digest: digest.toString("base64url"),
      value: signatureB64Url,
    });
    return out.value;
  }

  // -- secrets ---------------------------------------------------------------

  async setSecret(name: string, value: string, opts: SetSecretOptions = {}): Promise<KvSecret> {
    const attributes: Record<string, unknown> = {};
    if (opts.enabled !== undefined) attributes.enabled = opts.enabled;
    if (opts.expires !== undefined) attributes.expires = opts.expires;
    const res = await this.request(`/secrets/${encodeURIComponent(name)}`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        value,
        ...(opts.contentType ? { contentType: opts.contentType } : {}),
        attributes,
      }),
    });
    return SmaltKeyVaultClient.unwrap<KvSecret>(res);
  }

  async getSecret(name: string): Promise<KvSecret> {
    const secret = await SmaltKeyVaultClient.unwrap<KvSecret>(
      await this.request(`/secrets/${encodeURIComponent(name)}`, { method: "GET" }),
    );
    const exp = secret.attributes?.expires;
    if (typeof exp === "number" && exp * 1000 < Date.now()) {
      throw new KvError("SecretExpired", `secret "${name}" expired at ${exp}`, 200);
    }
    return secret;
  }

  async listSecrets(): Promise<KvSecret[]> {
    const body = await SmaltKeyVaultClient.unwrap<{ value: KvSecret[] }>(
      await this.request("/secrets", { method: "GET" }),
    );
    return body.value ?? [];
  }

  async deleteSecret(name: string): Promise<{ id: string }> {
    return SmaltKeyVaultClient.unwrap<{ id: string }>(
      await this.request(`/secrets/${encodeURIComponent(name)}`, { method: "DELETE" }),
    );
  }

  // -- ARM provisioning --------------------------------------------------------

  /** PUT a vault (control plane) — id/properties.vaultUri envelope. */
  async createVault(
    subId: string,
    rg: string,
    vaultName: string,
    location = "eastus",
  ): Promise<Record<string, unknown>> {
    const url =
      `${this.armBase}/subscriptions/${subId}/resourceGroups/${rg}/providers/` +
      `Microsoft.KeyVault/vaults/${vaultName}?api-version=${ARM_API_VERSION}`;
    const res = await this.fetchImpl(airFetch(url), {
      method: "PUT",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${await this.ensureToken(this.armBase)}`,
      },
      body: JSON.stringify({
        location,
        properties: { tenantId: this.tenant, sku: { family: "A", name: "standard" } },
      }),
    });
    return SmaltKeyVaultClient.unwrap(res);
  }

  /**
   * PUT an ARM vault secret child. Requires the parent vault to exist.
   * Cross-plane seeds the 8443 /secrets store — verify with getSecret.
   */
  async putArmVaultSecret(
    subId: string,
    rg: string,
    vaultName: string,
    secretName: string,
    value: string,
  ): Promise<Record<string, unknown>> {
    const url =
      `${this.armBase}/subscriptions/${subId}/resourceGroups/${rg}/providers/` +
      `Microsoft.KeyVault/vaults/${vaultName}/secrets/${secretName}?api-version=${ARM_API_VERSION}`;
    const res = await this.fetchImpl(airFetch(url), {
      method: "PUT",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${await this.ensureToken(this.armBase)}`,
      },
      body: JSON.stringify({
        location: "eastus",
        properties: { value, attributes: { enabled: true } },
      }),
    });
    return SmaltKeyVaultClient.unwrap(res);
  }
}

/**
 * Air-gap gate: every URL this client will ever touch is validated by
 * assertLocalUrl BEFORE fetchImpl runs (construction-time check covers the
 * two bases; this covers per-request derived URLs like the STS endpoint).
 */
/** The wire record nests the JWK under "key"; project it flat for callers. */
function flattenKey(record: Record<string, unknown>): KvKey {
  const jwk = (record["key"] ?? record) as KvKey;
  return {
    kid: (record["kid"] as string) ?? jwk.kid,
    kty: jwk.kty,
    keyOps: jwk.keyOps,
    n: jwk.n,
    e: jwk.e,
    attributes: (record["attributes"] as KvKey["attributes"]) ?? {},
  };
}

function airFetch(url: string): string {
  assertLocalUrl(url);
  return url;
}
