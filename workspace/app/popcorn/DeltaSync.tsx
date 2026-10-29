"use client";

/**
 * Stage delta → Sync (PRD §2.4). Client-side only: the session key is minted
 * per page load and never leaves the browser. signDelta() is an integrity
 * binding, not auth — the POST carries no Azure secrets and the sync route
 * still enforces its own admission policy.
 */

import { useCallback, useMemo, useRef, useState } from "react";
import { makeSessionKey, signDelta, verifyDelta } from "../../lib/delta";
import { assertLocalUrl } from "../../lib/smalt";

type SyncOutcome =
  | { state: "idle" }
  | { state: "sent"; status: number; body: string }
  | { state: "error"; message: string };

export default function DeltaSync() {
  // Session key is generated once per page load and held in a ref (client-only).
  const sessionKeyRef = useRef<string | null>(null);
  const [staged, setStaged] = useState("");
  const [outcome, setOutcome] = useState<SyncOutcome>({ state: "idle" });
  const [busy, setBusy] = useState(false);

  const sessionKey = useCallback((): string => {
    if (sessionKeyRef.current === null) sessionKeyRef.current = makeSessionKey();
    return sessionKeyRef.current;
  }, []);

  const parsed = useMemo<{ ok: true; delta: unknown } | { ok: false; error: string }>(() => {
    try {
      return { ok: true, delta: JSON.parse(staged || "null") };
    } catch (e) {
      return { ok: false, error: e instanceof Error ? e.message : String(e) };
    }
  }, [staged]);

  const onSync = useCallback(async () => {
    if (!parsed.ok) {
      setOutcome({ state: "error", message: `invalid JSON: ${parsed.error}` });
      return;
    }
    setBusy(true);
    try {
      const key = sessionKey();
      const sig = await signDelta(parsed.delta, key);
      if (!(await verifyDelta(parsed.delta, key, sig))) {
        setOutcome({ state: "error", message: "self-verify failed before POST" });
        return;
      }
      // Same-origin Next.js route, guarded through the air-gap assertLocalUrl.
      const res = await fetch(
        assertLocalUrl(new URL("/api/sync/state", window.location.origin).toString()),
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ delta: parsed.delta, sig }),
        },
      );
      setOutcome({
        state: "sent",
        status: res.status,
        body: (await res.text()).slice(0, 2000),
      });
    } catch (e) {
      setOutcome({
        state: "error",
        message: e instanceof Error ? e.message : String(e),
      });
    } finally {
      setBusy(false);
    }
  }, [parsed, sessionKey]);

  const tone =
    outcome.state === "sent" && outcome.status < 400 ? "#2e7d32" : "#b02a37";

  return (
    <div className="text-sm space-y-2">
      <p style={{ color: "var(--smalt-muted)" }}>
        HMAC-SHA256 over canonical JSON, keyed by a 32-byte per-page session key
        (client-side only). Integrity binding, not cloud auth — no Azure secrets
        in the client.
      </p>
      <textarea
        className="w-full border rounded p-2 font-mono text-xs"
        rows={5}
        placeholder='{"ops":[{"put":{"key":"a","value":"b"}}]}'
        value={staged}
        onChange={(e) => setStaged(e.target.value)}
      />
      <button
        type="button"
        className="border rounded px-3 py-1 font-medium"
        disabled={busy || !staged.trim()}
        onClick={onSync}
      >
        {busy ? "Syncing…" : "Stage delta → Sync"}
      </button>
      {outcome.state === "sent" && (
        <p style={{ color: tone }}>
          POST /api/sync/state → HTTP {outcome.status}
          {outcome.status < 400 ? " (applied)" : " (conflicts/refused)"}:{" "}
          <code>{outcome.body}</code>
        </p>
      )}
      {outcome.state === "error" && (
        <p style={{ color: "#b02a37" }}>sync failed: {outcome.message}</p>
      )}
    </div>
  );
}
