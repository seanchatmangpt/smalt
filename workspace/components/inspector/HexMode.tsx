/**
 * HexMode — raw hex payload view of the Navigator's selected node.
 *
 * Part of lane WS-3. Renders `node.payload` bytes as a classic 16-bytes-per-row
 * hex dump (offset | hex | ascii). Accepts a `Uint8Array` directly, or an
 * object payload (renders its UTF-8 encoding so the hex view always shows
 * bytes corresponding to what JsonMode shows). Non-printable and invalid
 * UTF-8 bytes render as `.` — never control characters.
 */
import type { InspectorNode } from "./ResourceInspector";
import { hexDump } from "@/lib/inspector/encoding";

export interface HexModeProps {
  node: InspectorNode;
}

function payloadToBytes(payload: InspectorNode["payload"]): Uint8Array {
  if (payload === undefined) return new Uint8Array(0);
  if (payload instanceof Uint8Array) return payload;
  try {
    return new TextEncoder().encode(JSON.stringify(payload, null, 2));
  } catch {
    return new TextEncoder().encode(String(payload));
  }
}

export default function HexMode({ node }: HexModeProps) {
  const bytes = payloadToBytes(node.payload);

  if (bytes.length === 0) {
    return (
      <div className="rounded border border-amber-700/40 bg-amber-950/20 p-3 text-sm text-amber-300">
        No payload bytes for node <code>{node.id}</code>.
      </div>
    );
  }

  const rows = hexDump(bytes);

  return (
    <div className="flex min-h-0 flex-col gap-2">
      <div className="text-xs text-neutral-400">
        {node.name} — {bytes.length} byte{bytes.length === 1 ? "" : "s"}
      </div>
      <div
        role="figure"
        aria-label={`Hex dump of ${node.name} payload, ${bytes.length} bytes`}
        className="max-h-full overflow-auto rounded bg-black/40 p-3"
      >
        <table className="font-mono text-xs leading-5">
          <thead>
            <tr className="text-neutral-500">
              <th scope="col" className="pr-4 text-left font-normal">Offset</th>
              <th scope="col" className="pr-4 text-left font-normal">Hex</th>
              <th scope="col" className="text-left font-normal">ASCII</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.offset}>
                <td className="pr-4 text-sky-300">{row.offset}</td>
                <td className="pr-4 whitespace-pre text-emerald-200">{row.hex}</td>
                <td className="whitespace-pre text-neutral-300">{row.ascii}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
