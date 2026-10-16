'use client';

/**
 * Sovereign Console (DoD-2 integration route) — composition only.
 *
 * Wires the four documented panel contracts together over the deterministic
 * fixture; no new feature logic. Selection flows WS-2 -> WS-3/WS-4, and the
 * WS-11 ledger renders read-only.
 *
 *   - TreeNavigator (WS-2): roots / selectedId / onSelect(nodeId)
 *   - ResourceInspector (WS-3): node (InspectorNode) + optional attestation
 *     (absent here — the inspector renders its honest unverified state)
 *   - CopilotPanel (WS-4): node (CopilotNodePayload)
 *   - ReceiptLedger (WS-11): snapshot (LedgerSnapshot), read-only
 */

import { useCallback, useMemo, useState } from 'react';
import { TreeNavigator } from '../../components/navigator/TreeNavigator';
import ResourceInspector, {
  type InspectorNode,
} from '../../components/inspector/ResourceInspector';
import CopilotPanel, {
  type CopilotNodePayload,
} from '../../components/copilot/CopilotPanel';
import { ReceiptLedger } from '../../components/compliance/ReceiptLedger';
import { childrenOf, type NavNode } from '../../lib/navigator/tree-model';
import { FIXTURE_ROOT } from '../../lib/navigator/fixtures';
import { getLedgerSnapshot, type LedgerSnapshot } from '../../lib/copilot/session-ledger';

/** Depth-first lookup over the fixture — composition plumbing, no domain logic. */
function findNode(roots: readonly NavNode[], id: string): NavNode | null {
  const stack: NavNode[] = [...roots];
  while (stack.length > 0) {
    const n = stack.pop()!;
    if (n.id === id) return n;
    for (const c of childrenOf(n)) stack.push(c);
  }
  return null;
}

export default function ConsolePage() {
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const onSelect = useCallback((nodeId: string) => setSelectedId(nodeId), []);

  const selectedNode = useMemo(
    () => (selectedId === null ? null : findNode(FIXTURE_ROOT, selectedId)),
    [selectedId],
  );

  const inspectorNode: InspectorNode | null = selectedNode
    ? {
        id: selectedNode.id,
        name: selectedNode.label,
        payload: { id: selectedNode.id, kind: selectedNode.kind, label: selectedNode.label },
      }
    : null;

  const copilotNode: CopilotNodePayload | null = selectedNode
    ? {
        id: selectedNode.id,
        type: selectedNode.kind,
        name: selectedNode.label,
      }
    : null;

  const ledger: LedgerSnapshot = useMemo(() => getLedgerSnapshot(), []);

  return (
    <main className="mx-auto max-w-7xl p-8">
      <h1 className="text-2xl font-semibold mb-4">Sovereign Console</h1>
      <div className="grid grid-cols-[minmax(280px,1fr)_2fr] gap-4">
        <TreeNavigator
          roots={FIXTURE_ROOT}
          selectedId={selectedId}
          onSelect={onSelect}
          height={560}
        />
        <div className="space-y-4">
          {inspectorNode ? (
            <ResourceInspector node={inspectorNode} />
          ) : (
            <p style={{ color: 'var(--smalt-muted)' }}>
              Select a node to inspect.
            </p>
          )}
          {copilotNode && <CopilotPanel node={copilotNode} />}
          <ReceiptLedger snapshot={ledger} />
        </div>
      </div>
    </main>
  );
}
