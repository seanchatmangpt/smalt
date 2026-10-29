// BFF reconciliation gateway: POST /api/sync/state — batched delta apply with
// server-side CAS against the loopback smalt cosmos face (data plane :8443).
//
// Contract:
//   Request body: [{ id, data, baseVersion?, sig? }, ...]
//     - id:          non-empty string (cosmos doc id)
//     - data:        JSON object — the full replacement body (cosmos replace
//                    semantics: the stored doc IS the body)
//     - baseVersion: optional etag string — the client's known version. When
//                    present, the apply is conditional on the server etag
//                    still matching; mismatch -> typed 409-class conflict row.
//                    When ABSENT on an existing doc, the apply runs as
//                    LWW-by-design (unconditional last-writer-wins replace):
//                    intentional and documented here — without a baseVersion
//                    the batch carries no client ordering signal and refusing
//                    would break first-sync flows. Caller posture: loopback
//                    gate always on (non-loopback Host/Origin -> typed 403);
//                    when SMALT_BFF_SYNC_SECRET is set the caller MUST also
//                    present x-smalt-sync-secret (typed 403 on missing/wrong,
//                    KD-171R). Env unset keeps the KD-171 loopback-open dev
//                    posture — no caller session exists.
//     - sig:         optional base64url string — the client's HMAC-SHA256
//                    (lib/delta.ts) over the canonical JSON of the delta.
//                    INTEGRITY BINDING ONLY, NOT AUTHENTICITY: the HMAC
//                    key is client-held per page load and never leaves the
//                    browser (lib/delta.ts auth boundary), so the server
//                    cannot verify an HMAC whose key never left the client.
//                    The server verifies STRUCTURE: a present `sig` must be
//                    canonical unpadded base64url of exactly 32 bytes (43
//                    chars) AND the delta (`data`) must carry `signedAt`.
//                    Tampered, truncated, or ill-formed sig -> typed
//                    per-entry refusal row reason "invalid_signature"
//                    (status "error"); the entry is NOT applied.
//   Response 200: { applied: [...], conflicts: [{ id, reason }], errors: [...] }
//   Response 400: { error, detail } — body not an array, or empty batch
//                 (typed whole-request refusal).
//
// Per-entry outcomes (best-effort batch: one bad entry never poisons the
// rest — each failure is a typed per-entry row, never a blind overwrite):
//   applied    -> entry echoed with the new etag from the write response
//   conflict   -> reason "version_conflict" (etag mismatch; server etag
//                 returned so the client can rebase) or "doc_not_found"
//   error      -> reason "invalid_entry" | "invalid_signature" |
//                 "read_<code>" | "write_<code>" | "create_<code>"
//
// All networking goes through smaltFetch (air-gap: assertLocalUrl).
// Auth to substrate: the substrate boots in :enforce mode, so the route
// presents a Bearer
// minted by the loopback STS. Env:
//   SMALT_SYNC_TOKEN   pre-minted bearer (set at launch; wins if present)
//   SMALT_TENANT       tenant id for STS mint (default "smalt")
//   SMALT_COSMOS_DB    target database  (default "sync")
//   SMALT_COSMOS_COLL  target container (default "state")

// NOTE: relative .ts-extension import (not "@/lib/smalt") so route.test.ts can
// import this module under `node --test` with native type stripping; enabled
// by allowImportingTsExtensions in tsconfig (noEmit already set). Next and the
// TS bundler resolution accept it identically.
import { smaltFetch, SMALT_EGRESS, SMALT_ARM } from "../../../../lib/smalt.ts";
import { assertSyncCaller } from "../../../../lib/caller-gate.ts";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const DB = process.env.SMALT_COSMOS_DB ?? "sync";
const COLL = process.env.SMALT_COSMOS_COLL ?? "state";
const TENANT = process.env.SMALT_TENANT ?? "smalt";

type Entry = {
  id: string;
  data: object;
  baseVersion: string | undefined;
  sig: string | undefined;
};

type PerEntry = {
  id: string;
  etag?: string;
  status: "applied" | "conflict" | "error";
  reason?: string;
  currentEtag?: string;
};

// ---- bearer: env token wins, else mint from the loopback STS, cached --------

let cachedToken: string | null = null;
let tokenExpiresAt = 0;

async function bearer(): Promise<string> {
  const envToken = process.env.SMALT_SYNC_TOKEN;
  if (envToken) return envToken;

  const now = Date.now();
  if (cachedToken && now < tokenExpiresAt) return cachedToken;

  const res = await smaltFetch(SMALT_ARM, `/${TENANT}/oauth2/v2.0/token`, {
      method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: "smalt-bff-sync",
      client_secret: "local-loopback",
      scope: "https://smalt.local/.default",
    }).toString(),
  });
  if (!res.ok) {
    throw new Error(`sts_mint_failed_${res.status}`);
  }
  const json = (await res.json()) as { access_token?: string; expires_in?: number };
  if (typeof json.access_token !== "string") {
    throw new Error("sts_mint_no_token");
  }
  cachedToken = json.access_token;
  tokenExpiresAt =
    now + (typeof json.expires_in === "number" ? json.expires_in : 3600) * 1000 - 60_000;
  return cachedToken;
}

// ---- cosmos face helpers ----------------------------------------------------

const COSMOS_HEADERS = {
  "x-ms-version": "2018-12-31_preview",
  accept: "application/json",
};

function authHeaders(token: string): Record<string, string> {
  return { authorization: `Bearer ${token}` };
}

function docPath(id: string): string {
  return `/dbs/${encodeURIComponent(DB)}/colls/${encodeURIComponent(COLL)}/docs/${encodeURIComponent(id)}`;
}

interface CosmosDoc {
  _etag?: string;
}

async function readDoc(
  id: string,
  token: string
): Promise<{ status: number; etag?: string }> {
  const res = await smaltFetch(SMALT_EGRESS, docPath(id), {
    headers: { ...COSMOS_HEADERS, ...authHeaders(token) },
  });
  if (res.status === 200) {
    const doc = (await res.json()) as CosmosDoc;
    return { status: 200, etag: doc._etag };
  }
  return { status: res.status };
}

// Create via POST with x-ms-documentdb-is-upsert (cosmos PUT replace 404s on
// a missing doc — creation is a POST op), returning status + fresh etag.
async function createDoc(
  id: string,
  data: object,
  token: string
): Promise<{ status: number; etag?: string }> {
  const res = await smaltFetch(SMALT_EGRESS, `/dbs/${encodeURIComponent(DB)}/colls/${encodeURIComponent(COLL)}/docs`, {
    method: "POST",
    headers: {
      ...COSMOS_HEADERS,
      ...authHeaders(token),
      "content-type": "application/json",
      "x-ms-documentdb-is-upsert": "true",
    },
    // Validated id wins: data.id must NEVER override the server-validated
    // doc identity (E7-2 — the applied row names exactly the stored doc).
    body: JSON.stringify({ ...data, id }),
  });
  const etag = res.headers.get("etag") ?? undefined;
  return { status: res.status, etag };
}

// PUT replace with If-Match when the client's baseVersion still matches.
// Returns the write status + fresh etag from the response `etag` header.
async function writeDoc(
  id: string,
  data: object,
  ifMatch: string | null,
  token: string
): Promise<{ status: number; etag?: string }> {
  const headers: Record<string, string> = {
    ...COSMOS_HEADERS,
    ...authHeaders(token),
    "content-type": "application/json",
  };
  if (ifMatch !== null) headers["if-match"] = ifMatch;
  const res = await smaltFetch(SMALT_EGRESS, docPath(id), {
    method: "PUT",
    headers,
    body: JSON.stringify(data),
  });
  const etag = res.headers.get("etag") ?? undefined;
  return { status: res.status, etag };
}

// ---- entry validation -------------------------------------------------------

function perEntryError(id: unknown, index: number, reason: string): PerEntry {
  return {
    id: typeof id === "string" ? id : `<entry ${index}>`,
    status: "error",
    reason,
  };
}

// Canonical unpadded base64url of exactly 32 bytes (a SHA-256 HMAC output,
// as emitted by lib/delta.ts bytesToBase64Url) is exactly 43 chars drawn from
// the base64url alphabet. Anything else is ill-formed -> invalid_signature.
const SIG_RE = /^[A-Za-z0-9_-]{43}$/;

export function validateEntry(
  entry: unknown,
  index: number
): { entry?: Entry; error?: PerEntry } {
  if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
    return { error: perEntryError(null, index, "invalid_entry") };
  }
  const e = entry as Record<string, unknown>;
  const id = e.id;
  if (typeof id !== "string" || id.length === 0) {
    return { error: perEntryError(id, index, "invalid_entry") };
  }
  if (typeof e.data !== "object" || e.data === null || Array.isArray(e.data)) {
    return { error: { id, status: "error", reason: "invalid_entry" } };
  }
  const bv = e.baseVersion;
  if (bv !== undefined && typeof bv !== "string") {
    return { error: { id, status: "error", reason: "invalid_entry" } };
  }
  // Integrity-binding check (NOT authenticity — see header contract): a
  // present `sig` must be canonical 32-byte base64url AND the delta must
  // carry `signedAt`. Ill-formed -> typed per-entry refusal, not applied.
  let sig: string | undefined;
  if (e.sig !== undefined) {
    if (
      typeof e.sig !== "string" ||
      !SIG_RE.test(e.sig) ||
      (e.data as Record<string, unknown>).signedAt === undefined
    ) {
      return { error: { id, status: "error", reason: "invalid_signature" } };
    }
    sig = e.sig;
  }
  return { entry: { id, data: e.data, baseVersion: bv, sig } };
}

// ---- caller gate (E7-1 loopback + KD-171R shared secret) --------------------
// The sync data plane is writable through this face. Gate order: loopback
// Host/Origin posture (E7-1) then, when SMALT_BFF_SYNC_SECRET is set, the
// x-smalt-sync-secret caller check — both live in lib/caller-gate.ts
// (KD-COVERS: KD-171). Env unset keeps the KD-171 loopback-open dev posture.

// ---- POST handler -----------------------------------------------------------

export async function POST(req: Request): Promise<Response> {
  const gate = assertSyncCaller(req);
  if (gate !== null) return gate;

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return Response.json(
      { error: "sync_state_invalid_json", detail: "body is not valid JSON" },
      { status: 400 }
    );
  }
  if (!Array.isArray(body)) {
    return Response.json(
      { error: "sync_state_invalid_batch", detail: "expected a JSON array batch" },
      { status: 400 }
    );
  }
  if (body.length === 0) {
    return Response.json(
      { error: "sync_state_empty_batch", detail: "batch must contain at least one entry" },
      { status: 400 }
    );
  }

  const applied: PerEntry[] = [];
  const conflicts: Array<{ id: string; reason: string; currentEtag?: string }> = [];
  const errors: Array<{ id: string; reason: string }> = [];

  for (let i = 0; i < body.length; i++) {
    const { entry, error } = validateEntry(body[i], i);
    if (error) {
      errors.push({ id: error.id, reason: error.reason ?? "invalid_entry" });
      continue;
    }
    const id = entry!.id;
    const data = entry!.data;
    const baseVersion = entry!.baseVersion;

    let token: string;
    try {
      token = await bearer();
    } catch (err) {
      return Response.json(
        { error: "sync_state_upstream_auth", detail: String(err) },
        { status: 502 }
      );
    }

    try {
      // CAS: read the current server etag, then write only if it still matches
      // the client's baseVersion. When etag matches, the If-Match write runs as
      // ONE atomic compare-and-swap inside the smalt Store — a concurrent
      // writer between read and write loses as a 412, never a silent overwrite.
      const cur = await readDoc(id, token);
      let ifMatch: string | null;
      if (cur.status === 404) {
        if (baseVersion !== undefined) {
          // client claims a prior version but the doc does not exist
          conflicts.push({ id, reason: "doc_not_found" });
          continue;
        }
        // cosmos PUT replace 404s on a missing doc: create via POST upsert
        const c = await createDoc(id, data, token);
        if (c.status === 201 || c.status === 200) {
          applied.push({ id, etag: c.etag, status: "applied" });
        } else {
          errors.push({ id, reason: `create_${c.status}` });
        }
        continue;
      } else if (cur.status !== 200) {
        errors.push({ id, reason: `read_${cur.status}` });
        continue;
      } else if (baseVersion === undefined) {
        ifMatch = null; // no baseVersion -> LWW-by-design (see header contract)
      } else if (cur.etag === baseVersion) {
        ifMatch = baseVersion; // still current -> atomic If-Match CAS
      } else {
        conflicts.push({ id, reason: "version_conflict", currentEtag: cur.etag });
        continue;
      }

      const w = await writeDoc(id, data, ifMatch, token);
      if (w.status === 200 || w.status === 201) {
        applied.push({ id, etag: w.etag, status: "applied" });
      } else if (w.status === 412) {
        // atomic CAS lost (concurrent writer between read and write)
        conflicts.push({ id, reason: "version_conflict", currentEtag: w.etag });
      } else {
        errors.push({ id, reason: `write_${w.status}` });
      }
    } catch (err) {
      errors.push({ id, reason: `transport_${String(err).slice(0, 120)}` });
    }
  }

  return Response.json({ applied, conflicts, errors }, { status: 200 });
}
