'use client';

/**
 * Migration console (T32WS) — zero-egress migrate console page.
 *
 * Typed finding: no loopback file-serving face serves migration-receipt.json
 * (no file tool on the MCP surface, no file face on the egress router), so
 * this page performs ZERO network I/O. The manifest schema explainer is
 * static; the manifest and migration receipt are parsed client-side (paste
 * or File API drag-drop). No fetch calls of any kind.
 */

import { useMemo, useState } from 'react';

// ---------------------------------------------------------------------------
// Typed parsing (fail-closed)
// ---------------------------------------------------------------------------

interface ReceiptCheck {
  name: string;
  ok: boolean;
}

interface ReceiptService {
  service: string;
  checks: ReceiptCheck[];
  skippedCount: number;
  allChecksPassed: boolean;
}

type ManifestResult =
  | { kind: 'ok'; value: Record<string, unknown> }
  | { kind: 'refused'; reason: string }
  | null;

type ReceiptResult =
  | { kind: 'ok'; services: ReceiptService[] }
  | { kind: 'refused'; reason: string }
  | null;

function parseJson(
  text: string,
): { ok: true; value: unknown } | { ok: false; reason: string } {
  if (text.trim() === '') return { ok: false, reason: 'empty' };
  try {
    return { ok: true, value: JSON.parse(text) };
  } catch (e) {
    return { ok: false, reason: `invalid JSON: ${String(e).slice(0, 160)}` };
  }
}

function parseManifest(text: string): ManifestResult {
  const p = parseJson(text);
  if (!p.ok) return p.reason === 'empty' ? null : { kind: 'refused', reason: p.reason };
  const v = p.value;
  if (v === null || typeof v !== 'object' || Array.isArray(v)) {
    return { kind: 'refused', reason: 'manifest must be a JSON object' };
  }
  const m = v as Record<string, unknown>;
  if (m.version !== 1) {
    return {
      kind: 'refused',
      reason: `unsupported manifest version ${JSON.stringify(m.version)} (expected 1)`,
    };
  }
  for (const key of MANIFEST_KEYS) {
    const val = m[key];
    if (val !== undefined && !Array.isArray(val)) {
      return { kind: 'refused', reason: `manifest.${key} must be an array` };
    }
  }
  return { kind: 'ok', value: m };
}

function parseReceipt(text: string): ReceiptResult {
  const p = parseJson(text);
  if (!p.ok) return p.reason === 'empty' ? null : { kind: 'refused', reason: p.reason };
  const v = p.value;
  if (v === null || typeof v !== 'object' || Array.isArray(v)) {
    return { kind: 'refused', reason: 'receipt must be a JSON object with a "services" array' };
  }
  const services = (v as Record<string, unknown>).services;
  if (!Array.isArray(services)) {
    return { kind: 'refused', reason: 'receipt.services must be an array' };
  }
  const typed: ReceiptService[] = [];
  for (const svc of services) {
    if (svc === null || typeof svc !== 'object') {
      return { kind: 'refused', reason: 'receipt.services entries must be objects' };
    }
    const s = svc as Record<string, unknown>;
    const service = typeof s.service === 'string' ? s.service : '(unnamed)';
    const checks: ReceiptCheck[] = [];
    if (Array.isArray(s.checks)) {
      for (const c of s.checks) {
        if (c !== null && typeof c === 'object' && typeof (c as ReceiptCheck).name === 'string') {
          checks.push({ name: (c as ReceiptCheck).name, ok: Boolean((c as ReceiptCheck).ok) });
        } else {
          checks.push({ name: '(malformed check)', ok: false });
          break;
        }
      }
    }
    typed.push({
      service,
      checks,
      skippedCount: Array.isArray(s.skipped) ? s.skipped.length : 0,
      allChecksPassed:
        Boolean(s.all_checks_passed) && checks.length > 0 && checks.every((c) => c.ok),
    });
  }
  return { kind: 'ok', services: typed };
}

// ---------------------------------------------------------------------------
// Manifest IR — mirrors smalt_cli/migrate/manifest.py build_manifest
// ---------------------------------------------------------------------------

const MANIFEST_KEYS = [
  'identity',
  'cosmos_databases',
  'apim_gateways',
  'messaging_namespaces',
  'security_vaults',
  'object_storage',
  'seed_fixtures',
];

interface SectionSpec {
  key: string;
  desc: string;
}

const MANIFEST_SECTIONS: SectionSpec[] = [
  { key: 'services', desc: 'Discovered services with a verify.py verifier (sorted).' },
  {
    key: 'unverifiable_services',
    desc: 'Services with no verifier — typed remainder, never dropped.',
  },
  { key: 'identity', desc: 'Identity resources (currently an empty list).' },
  {
    key: 'cosmos_databases',
    desc: 'Cosmos accounts -> databases -> containers (+ per-container seed documents).',
  },
  { key: 'apim_gateways', desc: 'API Management gateways.' },
  { key: 'messaging_namespaces', desc: 'Service Bus / Event Hubs namespaces.' },
  { key: 'security_vaults', desc: 'Key Vault vaults.' },
  { key: 'object_storage', desc: 'Storage accounts (blob).' },
  { key: 'seed_fixtures', desc: 'One seed row per resolved cosmos container.' },
];

const RECEIPT_SERVICE_LABELS: Record<string, string> = {
  blob: 'Storage Blob',
  cosmos: 'Cosmos DB',
  kv: 'Key Vault',
  servicebus: 'Service Bus',
  eventhubs: 'Event Hubs',
};

/** Cosmos section nests accounts -> databases -> containers. */
function cosmosContainerCount(v: unknown): number {
  if (!Array.isArray(v)) return 0;
  let n = 0;
  for (const acct of v) {
    if (acct === null || typeof acct !== 'object') continue;
    const a = acct as { databases?: unknown; containers?: unknown };
    for (const db of Array.isArray(a.databases) ? a.databases : []) {
      const d = db as { containers?: unknown };
      if (d && typeof d === 'object' && Array.isArray(d.containers)) {
        n += d.containers.length;
      }
    }
    if (Array.isArray(a.containers)) n += a.containers.length;
  }
  return n;
}

function sectionCount(key: string, v: unknown): number | null {
  if (key === 'cosmos_databases') return cosmosContainerCount(v);
  if (Array.isArray(v)) return v.length;
  return null;
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

export default function MigratePage() {
  const [manifestText, setManifestText] = useState('');
  const [receiptText, setReceiptText] = useState('');

  const manifest = useMemo(() => parseManifest(manifestText), [manifestText]);
  const receipt = useMemo(() => parseReceipt(receiptText), [receiptText]);

  function readFile(kind: 'manifest' | 'receipt', file: File): void {
    void file.text().then((text) => {
      if (kind === 'manifest') setManifestText(text);
      else setReceiptText(text);
    });
  }

  function dropHandler(kind: 'manifest' | 'receipt') {
    return (e: React.DragEvent<HTMLDivElement>) => {
      e.preventDefault();
      const f = e.dataTransfer.files?.[0];
      if (f) readFile(kind, f);
    };
  }

  const okManifest = manifest && manifest.kind === 'ok' ? manifest.value : null;
  const okServices = receipt && receipt.kind === 'ok' ? receipt.services : null;

  return (
    <main className="mx-auto max-w-5xl p-8">
      <div className="mb-6 flex items-baseline justify-between gap-4">
        <h1 className="text-2xl font-semibold">Migration</h1>
        <span
          data-testid="zero-egress-badge"
          title="No network I/O: manifest and receipt are parsed client-side (paste / File API) only."
          className="rounded bg-emerald-900 px-2 py-0.5 text-xs font-mono text-emerald-200"
        >
          ZERO-EGRESS
        </span>
      </div>

      {/* -- Manifest schema explainer + per-section counts ---------------- */}
      <section className="mb-8">
        <h2 className="mb-2 text-lg font-medium">smalt.manifest.json schema</h2>
        <p className="mb-2 text-xs" style={{ color: 'var(--smalt-muted)' }}>
          Produced by <code>smalt-migrate generate</code> — deterministic topology IR (no
          timestamps). Paste or drop a manifest to see per-section resource counts.
        </p>
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-neutral-700">
              <th className="py-1 pr-4 font-medium">section</th>
              <th className="py-1 pr-4 font-medium">resources</th>
              <th className="font-medium">description</th>
            </tr>
          </thead>
          <tbody>
            {MANIFEST_SECTIONS.map((s) => {
              const val = okManifest ? okManifest[s.key] : undefined;
              const n = val === undefined ? null : sectionCount(s.key, val);
              return (
                <tr key={s.key} className="border-b border-neutral-800">
                  <td className="py-1 pr-4 font-mono text-xs">{s.key}</td>
                  <td className="py-1 pr-4 font-mono text-xs" data-testid={`count-${s.key}`}>
                    {n === null ? '—' : String(n)}
                  </td>
                  <td className="text-xs" style={{ color: 'var(--smalt-muted)' }}>
                    {s.desc}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
        {manifest && manifest.kind === 'refused' && (
          <p className="mt-1 text-xs text-red-400" data-testid="manifest-refusal">
            REFUSED: {manifest.reason}
          </p>
        )}
        <div
          onDrop={dropHandler('manifest')}
          onDragOver={(e) => e.preventDefault()}
          className="mt-2 rounded border border-dashed border-neutral-600 p-3 text-xs"
          style={{ color: 'var(--smalt-muted)' }}
        >
          Drop smalt.manifest.json here, or paste below. Client-side parse only.
        </div>
        <textarea
          className="mt-2 h-28 w-full rounded border border-neutral-700 bg-neutral-900 p-2 font-mono text-xs"
          placeholder={'{ "version": 1, ... }'}
          value={manifestText}
          onChange={(e) => setManifestText(e.target.value)}
        />
      </section>

      {/* -- Receipt input + per-service verify table ----------------------- */}
      <section>
        <h2 className="mb-2 text-lg font-medium">
          Migration receipt — per-service verify status
        </h2>
        <div
          onDrop={dropHandler('receipt')}
          onDragOver={(e) => e.preventDefault()}
          className="mb-2 rounded border border-dashed border-neutral-600 p-3 text-xs"
          style={{ color: 'var(--smalt-muted)' }}
        >
          Drop migration-receipt.json here, or paste below. Client-side parse only.
        </div>
        <textarea
          className="h-28 w-full rounded border border-neutral-700 bg-neutral-900 p-2 font-mono text-xs"
          placeholder={'{ "services": [ ... ] }'}
          value={receiptText}
          onChange={(e) => setReceiptText(e.target.value)}
        />
        {receipt && receipt.kind === 'refused' && (
          <p className="mt-1 text-xs text-red-400" data-testid="receipt-refusal">
            REFUSED: {receipt.reason}
          </p>
        )}
        {okServices && (
          <table className="mt-3 w-full text-left text-sm">
            <thead>
              <tr className="border-b border-neutral-700">
                <th className="py-1 pr-4 font-medium">service</th>
                <th className="py-1 pr-4 font-medium">checks</th>
                <th className="py-1 pr-4 font-medium">skipped</th>
                <th className="font-medium">status</th>
              </tr>
            </thead>
            <tbody>
              {okServices.map((svc, i) => (
                <tr key={svc.service + String(i)} className="border-b border-neutral-800">
                  <td className="py-1 pr-4 font-mono text-xs">
                    {RECEIPT_SERVICE_LABELS[svc.service] ?? svc.service}
                  </td>
                  <td className="py-1 pr-4 font-mono text-xs">
                    {svc.checks.filter((c) => c.ok).length}/{svc.checks.length} ok
                  </td>
                  <td className="py-1 pr-4 font-mono text-xs">{String(svc.skippedCount)}</td>
                  <td className="py-1 font-mono text-xs">
                    {svc.allChecksPassed ? (
                      <span className="text-emerald-400">PASS</span>
                    ) : (
                      <span className="text-red-400">FAIL</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </main>
  );
}
