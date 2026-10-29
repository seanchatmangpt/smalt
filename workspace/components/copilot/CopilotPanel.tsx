'use client';

/**
 * Zero-Actuation Copilot Panel (lane WS-4).
 *
 * The advisor is a deterministic local function over the node payload —
 * no external LLM, no egress. Suggestions pass the verb-gate at the UI
 * layer; mutation-shaped suggestions render as typed refusals. Live
 * refusals from guardedFetch surface in the same stream.
 */

import { useCallback, useMemo, useState } from 'react';
import { checkSuggestion, type SuggestionOp } from '@/lib/copilot/verb-gate';
import { makeRefusal, type TypedRefusal } from '@/lib/copilot/typed-refusal';
import { guardedFetch, getLedgerSnapshot } from '@/lib/copilot/session-ledger';
import styles from './CopilotPanel.module.css';

export interface CopilotNodePayload {
  id: string;
  type: string;
  name: string;
  status?: string;
  metrics?: Record<string, number>;
}

interface Suggestion {
  op: SuggestionOp;
  label: string;
  refusedReason: string | null;
}

/** Deterministic local advisor: read-only diagnostics from the node payload. */
function advise(node: CopilotNodePayload): Suggestion[] {
  const out: Suggestion[] = [
    {
      op: { op: `${node.type}/read`, method: 'GET' },
      label: `Read current config of ${node.name}`,
      refusedReason: null,
    },
    {
      op: { op: '/subscriptions', method: 'GET' },
      label: 'List subscriptions and locate the resource group',
      refusedReason: null,
    },
    {
      op: { op: `providers/Microsoft.Insights/metrics?resource=${node.id}`, method: 'GET' },
      label: `Fetch metrics for ${node.name}`,
      refusedReason: null,
    },
  ];

  if (node.type.includes('virtualMachines')) {
    out.push({
      op: { op: `Microsoft.Compute/virtualMachines/${node.name}/write`, method: 'PUT' },
      label: `Reconfigure ${node.name} (write)`,
      refusedReason: checkSuggestion({ op: `Microsoft.Compute/virtualMachines/${node.name}/write`, method: 'PUT' }),
    });
    out.push({
      op: { op: `Microsoft.Compute/virtualMachines/${node.name}/delete`, method: 'DELETE' },
      label: `Delete ${node.name}`,
      refusedReason: checkSuggestion({ op: `Microsoft.Compute/virtualMachines/${node.name}/delete`, method: 'DELETE' }),
    });
  }
  if (node.type.includes('secrets')) {
    out.push({
      op: { op: `Microsoft.KeyVault/vaults/secrets/${node.name}`, method: 'POST' },
      label: `Rotate secret ${node.name}`,
      refusedReason: checkSuggestion({ op: `Microsoft.KeyVault/vaults/secrets/${node.name}`, method: 'POST' }),
    });
  }
  out.push({
    op: { op: `Microsoft.Resources/deployments/${node.name}-deploy`, method: 'POST' },
    label: `Redeploy ${node.name} resource group`,
    refusedReason: checkSuggestion({ op: `Microsoft.Resources/deployments/${node.name}-deploy`, method: 'POST' }),
  });

  return out;
}

export default function CopilotPanel({ node }: { node: CopilotNodePayload }) {
  const [refusals, setRefusals] = useState<TypedRefusal[]>([]);
  const [readLog, setReadLog] = useState<string[]>([]);

  const suggestions = useMemo(() => advise(node), [node]);

  const attempt = useCallback(async (op: SuggestionOp, _label: string) => {
    const gate = checkSuggestion(op);
    if (gate !== null) {
      // UI-suggestion-layer refusal: deterministic, ledger-free (not a fetch).
      setRefusals((r) => [makeRefusal(gate, op.method ?? 'OP', op.op ?? ''), ...r]);
      return;
    }
    const result = await guardedFetch(op.op ?? '/', { method: op.method ?? 'GET' });
    if (result.refusal) {
      setRefusals((r) => [result.refusal as TypedRefusal, ...r]);
    } else {
      setReadLog((l) => [`${op.method} ${op.op} -> ok`, ...l].slice(0, 20));
    }
  }, []);

  const snapshot = getLedgerSnapshot();

  return (
    <section className={styles.panel} aria-label="Zero-actuation copilot">
      <h2 className={styles.title}>Copilot — {node.name}</h2>
      <p className={styles.law}>
        Zero actuation: mutation verbs are refused before any network call.
        Ledger: {snapshot.length} entries, chain {snapshot.intact ? 'intact' : 'BROKEN'}.
      </p>

      <ul className={styles.suggestions}>
        {suggestions.map((s, i) => (
          <li key={i} className={s.refusedReason ? styles.refusedSuggestion : styles.suggestion}>
            <span>{s.label}</span>
            {s.refusedReason ? (
              <strong className={styles.reason}>[{s.refusedReason}]</strong>
            ) : (
              <button className={styles.run} onClick={() => attempt(s.op, s.label)}>
                run (read-only)
              </button>
            )}
          </li>
        ))}
      </ul>

      {refusals.length > 0 && (
        <div className={styles.refusals}>
          <h3 className={styles.subtitle}>Typed refusals</h3>
          <ul>
            {refusals.map((r, i) => (
              <li key={i} className={styles.refusal}>
                reason={r.reason} verb={r.verb} url={r.url} ts={r.ts}
              </li>
            ))}
          </ul>
        </div>
      )}

      {readLog.length > 0 && (
        <div className={styles.reads}>
          <h3 className={styles.subtitle}>Read log</h3>
          <ul>
            {readLog.map((l, i) => (
              <li key={i} className={styles.read}>{l}</li>
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}
