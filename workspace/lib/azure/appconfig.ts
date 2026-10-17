/**
 * App Configuration client — Azure App Configuration wire contract over
 * smaltFetch (air-gapped loopback only).
 *
 * SUBSTRATE REALITY (2026-10-16, lane 527 Agent 7): smalt has NO App
 * Configuration data plane. GET /appconfig on the 8443 egress plane returns
 * typed 404 {"error":{"code":"RouteNotFound",...}} (witnessed). The client
 * below implements the real Azure wire contract
 * (docs/jira/v26.10.16/sdk-results/appconfig-console-gap.md); wire paths run
 * today against a contract mock (test/appconfig_features.test.ts) and are
 * substrate-pending for the live emulator.
 *
 * Wire contract implemented (Azure App Configuration REST, api-version=1.0):
 *  - kv CRUD: GET/PUT/DELETE {base}/kv/{key}?label={label}&api-version=1.0
 *  - list:    GET {base}/kv?label=...&key=...&api-version=1.0
 *  - ETag conditional requests: If-Match on PUT/DELETE (412 on mismatch),
 *    If-None-Match on GET (304 on match)
 *  - feature-flag content type:
 *    application/vnd.microsoft.appconfig.kv+json;ctype-feature
 *  - sentinel-key watch: poll GET kv/{sentinel} and compare ETag
 */

import { smaltFetch } from "../smalt.js"; // SHIM-COURT: air-gap egress via smaltFetch

export const FEATURE_FLAG_CONTENT_TYPE =
  "application/vnd.microsoft.appconfig.kv+json;ctype-feature";

export const APPCONFIG_API_VERSION = "1.0";

/** A setting as it appears on the wire. */
export interface AppConfigSetting {
  key: string;
  label?: string;
  /** Raw value — JSON for feature flags, string otherwise. */
  value: string | undefined;
  contentType?: string;
  etag?: string;
  lastModified?: string;
  tags?: Record<string, string>;
}

/** Azure feature-flag JSON body (conditions.client_filters). */
export interface FeatureFlag {
  id: string;
  description?: string;
  enabled: boolean;
  conditions?: {
    client_filters: Array<{
      name: string;
      parameters?: Record<string, unknown>;
    }>;
    requirement_type?: "Any" | "All";
  };
}

/** Context a console evaluates feature flags against. */
export interface FeatureEvaluationContext {
  /** Stable per-user id — required by the percentage filter. */
  userId?: string;
  /** Instant used by the time-window filter (defaults to now). */
  now?: Date;
  /**
   * Deterministic unit-interval hash override for the percentage filter.
   * Production falls back to a sha256(userId) fraction; tests inject a
   * fixed value so evaluations are reproducible.
   */
  hashOverride?: number;
}

export interface AppConfigClientOptions {
  base: string;
  /** Bearer token (enforce-mode smalt auth). */
  token?: string;
  fetchImpl?: typeof fetch;
}

export class AppConfigError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message: string) {
    super(`AppConfig ${status} ${code}: ${message}`);
    this.name = "AppConfigError";
    this.status = status;
    this.code = code;
  }
}

/** Low-level kv CRUD over the App Configuration wire contract. */
export class AppConfigClient {
  private readonly base: string;
  private readonly token?: string;
  /** Custom fetch override (tests) — receives the full URL. */
  private readonly fetchImpl?: typeof fetch;

  constructor(opts: AppConfigClientOptions) {
    this.base = opts.base.replace(/\/$/, "");
    this.token = opts.token;
    this.fetchImpl = opts.fetchImpl;
  }

  private rawFetch(url: string, init: RequestInit): Promise<Response> {
    // Custom impl (tests) bypasses the air-gap guard by design; production
    // always rides smaltFetch, which re-validates the localhost-only rule.
    return this.fetchImpl
      ? this.fetchImpl(url, init)
      : smaltFetch(this.base, url.slice(this.base.length), init);
  }

  private async req(
    method: string,
    path: string,
    init: { headers?: Record<string, string>; body?: string } = {},
  ): Promise<Response> {
    const headers: Record<string, string> = { ...init.headers };
    if (this.token) headers.authorization = `Bearer ${this.token}`;
    const res = await this.rawFetch(`${this.base}${path}`, {
      method,
      headers,
      body: init.body,
    });
    return res;
  }

  private static async toError(res: Response): Promise<AppConfigError> {
    let code = "Unknown";
    let detail = "";
    try {
      const body = (await res.json()) as { detail?: string };
      code = res.headers.get("x-smalt-error") ?? code;
      detail = body.detail ?? "";
    } catch {
      /* non-JSON error body — keep defaults */
    }
    return new AppConfigError(res.status, code, detail || `HTTP ${res.status}`);
  }

  /** GET /kv/{key} with If-None-Match support. Returns null on 304. */
  async get(
    key: string,
    opts: { label?: string; ifNoneMatch?: string } = {},
  ): Promise<AppConfigSetting | null> {
    const q = new URLSearchParams({ "api-version": APPCONFIG_API_VERSION });
    if (opts.label) q.set("label", opts.label);
    const headers: Record<string, string> = {};
    if (opts.ifNoneMatch) headers["if-none-match"] = opts.ifNoneMatch;
    const res = await this.req("GET", `/kv/${encodeURIComponent(key)}?${q}`, { headers });
    if (res.status === 304) return null;
    if (res.status === 404) return null;
    if (!res.ok) throw await AppConfigClient.toError(res);
    return (await res.json()) as AppConfigSetting;
  }

  /**
   * PUT /kv/{key} — create or update. ETag semantics: Azure App Config
   * PUT requires If-Match="*" to overwrite an existing kv and refuses an
   * unconditional overwrite of an existing value with 409; create with
   * If-None-Match="*" refuses a duplicate with 412.
   */
  async put(
    key: string,
    value: string,
    opts: {
      label?: string;
      contentType?: string;
      /** "*" = overwrite any; an exact etag = compare-and-swap. */
      ifMatch?: string;
      /** "*" = create-only. */
      ifNoneMatch?: string;
    } = {},
  ): Promise<AppConfigSetting> {
    const q = new URLSearchParams({ "api-version": APPCONFIG_API_VERSION });
    if (opts.label) q.set("label", opts.label);
    const headers: Record<string, string> = {
      "content-type": "application/json",
    };
    if (opts.ifMatch) headers["if-match"] = opts.ifMatch;
    if (opts.ifNoneMatch) headers["if-none-match"] = opts.ifNoneMatch;
    const res = await this.req("PUT", `/kv/${encodeURIComponent(key)}?${q}`, {
      headers,
      body: JSON.stringify({
        key,
        value,
        label: opts.label ?? "",
        contentType: opts.contentType,
      }),
    });
    if (!res.ok) throw await AppConfigClient.toError(res);
    return (await res.json()) as AppConfigSetting;
  }

  /** DELETE /kv/{key} — If-Match required by the contract; "*" deletes any. */
  async del(key: string, opts: { label?: string; ifMatch?: string } = {}): Promise<void> {
    const q = new URLSearchParams({ "api-version": APPCONFIG_API_VERSION });
    if (opts.label) q.set("label", opts.label);
    const headers: Record<string, string> = {
      "if-match": opts.ifMatch ?? "*",
    };
    const res = await this.req("DELETE", `/kv/${encodeURIComponent(key)}?${q}`, { headers });
    if (res.status === 404) return;
    if (!res.ok) throw await AppConfigClient.toError(res);
  }

  /** GET /kv — list with key/label filters. */
  async list(opts: { key?: string; label?: string } = {}): Promise<AppConfigSetting[]> {
    const q = new URLSearchParams({ "api-version": APPCONFIG_API_VERSION });
    if (opts.key) q.set("key", opts.key);
    if (opts.label) q.set("label", opts.label);
    const res = await this.req("GET", `/kv?${q}`);
    if (!res.ok) throw await AppConfigClient.toError(res);
    const body = (await res.json()) as { items?: AppConfigSetting[] };
    return body.items ?? [];
  }

  // --- feature flags -------------------------------------------------------

  /** Put a feature flag (correct wire content type, JSON-encoded). */
  async putFeatureFlag(
    key: string,
    flag: FeatureFlag,
    opts: { label?: string } = {},
  ): Promise<AppConfigSetting> {
    return this.put(key, JSON.stringify(flag), {
      ...opts,
      contentType: FEATURE_FLAG_CONTENT_TYPE,
    });
  }

  /** Get + parse a feature flag. Returns null when the kv is absent. */
  async getFeatureFlag(
    key: string,
    opts: { label?: string } = {},
  ): Promise<FeatureFlag | null> {
    const s = await this.get(key, opts);
    if (!s) return null;
    return parseFeatureFlag(s.value ?? "");
  }

  /**
   * Sentinel hot-reload: watch a sentinel kv's ETag and invoke `onChange`
   * whenever it changes. Returns a stop function.
   */
  watchSentinel(
    sentinelKey: string,
    onChange: (setting: AppConfigSetting | null) => void | Promise<void>,
    opts: { label?: string; pollMs?: number; signal?: AbortSignal } = {},
  ): () => void {
    const pollMs = opts.pollMs ?? 5_000;
    let lastEtag: string | undefined;
    let stopped = false;
    const timer = setInterval(() => {
      if (stopped) return;
      void (async () => {
        try {
          const s = await this.get(sentinelKey, { label: opts.label });
          const etag = s?.etag;
          if (etag !== lastEtag) {
            const first = lastEtag === undefined && s === null;
            lastEtag = etag;
            if (!first) await onChange(s);
          }
        } catch (e) {
          // A watch must not die on a transient error; surface it, keep polling.
          console.error(`[appconfig] sentinel watch error: ${String(e)}`);
        }
      })();
    }, pollMs);
    return () => {
      stopped = true;
      clearInterval(timer);
    };
  }
}

// ---------------------------------------------------------------------------
// Pure feature-flag parsing + client-side evaluation (no substrate needed)
// ---------------------------------------------------------------------------

/** Parse a kv value as a feature flag; throws on non-flag content. */
export function parseFeatureFlag(raw: string | undefined): FeatureFlag {
  if (!raw) throw new Error("empty feature-flag value");
  let parsed: FeatureFlag;
  try {
    parsed = JSON.parse(raw) as FeatureFlag;
  } catch (e) {
    throw new Error(`invalid feature-flag payload: not JSON (${String(e).slice(0, 80)})`);
  }
  if (typeof parsed !== "object" || typeof parsed.id !== "string" ||
    typeof parsed.enabled !== "boolean") {
    throw new Error(
      `invalid feature-flag payload: need {id: string, enabled: boolean}, got ${JSON.stringify(
        raw.slice(0, 80),
      )}`,
    );
  }
  if (parsed.conditions && !Array.isArray(parsed.conditions.client_filters)) {
    throw new Error("invalid feature-flag conditions: client_filters must be an array");
  }
  return parsed;
}

/** True when the kv contentType marks a feature flag. */
export function isFeatureFlagContentType(contentType?: string): boolean {
  return (contentType ?? "").startsWith(FEATURE_FLAG_CONTENT_TYPE.split(";")[0]);
}

function sha256Fraction(input: string): number {
  // Synchronous pure hash — a stable 0..1 fraction, sufficient for bucketing.
  let h1 = 0xdeadbeef;
  let h2 = 0x41c6ce57;
  for (let i = 0; i < input.length; i++) {
    const ch = input.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761);
    h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507);
  h2 = Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  const h = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  return ((h >>> 0) % 10_000) / 10_000;
}

/**
 * Client-side evaluation of a feature flag against a context.
 *
 * Filters implemented (Azure vocabulary):
 *  - no filters           → enabled as-is
 *  - "Microsoft.Percentage" {Value: 0..100} — deterministic bucket on userId
 *  - "Microsoft.TimeWindow" {Start, End} — inclusive window, ISO strings
 *  - "Microsoft.Targeting" {Audience: {Users: []}} — user membership
 *  - alias "{Alias: true}" / name "AlwaysOn" → true
 *  - unknown filter → false (fail-closed)
 *
 * requirement_type "All" requires every filter to pass; "Any"/default is
 * pass-on-first.
 */
export function evaluateFeatureFlag(
  flag: FeatureFlag,
  ctx: FeatureEvaluationContext = {},
): boolean {
  if (!flag.enabled) return false;
  const filters = flag.conditions?.client_filters ?? [];
  if (filters.length === 0) return true;
  const anyAll = flag.conditions?.requirement_type ?? "Any";
  const results = filters.map((f) => evaluateFilter(f, ctx));
  return anyAll === "All" ? results.every(Boolean) : results.some(Boolean);
}

function evaluateFilter(
  f: { name: string; parameters?: Record<string, unknown> },
  ctx: FeatureEvaluationContext,
): boolean {
  const name = f.name.toLowerCase().replace(/^microsoft\.treatmentfeaturefilter/i, "");
  if (f.name === "{Alias} always on" || f.name.toLowerCase() === "alwayson") return true;
  switch (name) {
    case "microsoft.percentage": {
      const pct = Number(f.parameters?.Value ?? f.parameters?.value ?? NaN);
      if (!Number.isFinite(pct)) return false;
      const frac = ctx.hashOverride ?? sha256Fraction(ctx.userId ?? "");
      return frac * 100 < pct;
    }
    case "microsoft.timewindow": {
      const start = f.parameters?.Start ?? f.parameters?.start;
      const end = f.parameters?.End ?? f.parameters?.end;
      const now = (ctx.now ?? new Date()).getTime();
      if (typeof start === "string" && now < new Date(start).getTime()) return false;
      if (typeof end === "string" && now > new Date(end).getTime()) return false;
      return true;
    }
    case "microsoft.targeting": {
      const aud = f.parameters?.Audience ?? f.parameters?.audience;
      const users = (aud as { Users?: string[]; users?: string[] } | undefined) ?? {};
      const list = users.Users ?? users.users ?? [];
      return typeof ctx.userId === "string" && list.includes(ctx.userId);
    }
    default:
      return false; // fail-closed on unknown filters
  }
}
