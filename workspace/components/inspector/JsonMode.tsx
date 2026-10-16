/**
 * JsonMode — JSON telemetry manifest view of the selected node.
 *
 * Part of lane WS-3 (Multi-Mode Resource Inspector). Props contract is owned
 * by ResourceInspector.tsx; this component receives the already-narrowed tab
 * props and renders `node.payload` as pretty-printed JSON. When the payload is
 * raw bytes, it decodes via decodePreview (UTF-8-safe) and pretty-prints if
 * the content parses as JSON; otherwise shows an honest "not JSON" state.
 */
import type { InspectorNode } from "./ResourceInspector";
import { decodePreview, safeJsonStringify } from "@/lib/inspector/encoding";

export interface JsonModeProps {
  node: InspectorNode;
}

export default function JsonMode({ node }: JsonModeProps) {
  const payload = node.payload;

  if (payload === undefined) {
    return (
      <div className="rounded border border-amber-700/40 bg-amber-950/20 p-3 text-sm text-amber-300">
        No payload attached to node <code>{node.id}</code>.
      </div>
    );
  }

  if (!(payload instanceof Uint8Array)) {
    return (
      <pre
        className="max-h-full overflow-auto rounded bg-black/40 p-3 font-mono text-xs leading-5 text-emerald-200"
        aria-label={`JSON manifest for ${node.name}`}
      >
        {safeJsonStringify(payload)}
      </pre>
    );
  }

  const preview = decodePreview(payload);
  return (
    <div className="flex min-h-0 flex-col gap-2">
      <div className="text-xs text-neutral-400">
        {preview.kind === "json"
          ? "UTF-8 JSON payload"
          : preview.kind === "etf"
            ? "ETF envelope — structural decode owned by ETF codec lane"
            : preview.kind === "text"
              ? "UTF-8 text (not valid JSON)"
              : "Binary payload (shown as safe UTF-8)"}
      </div>
      <pre
        className="max-h-full overflow-auto rounded bg-black/40 p-3 font-mono text-xs leading-5 text-emerald-200"
        aria-label={`Payload for ${node.name}`}
      >
        {preview.text}
      </pre>
    </div>
  );
}
