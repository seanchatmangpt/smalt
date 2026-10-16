'use client';

/**
 * TreeNavigator — WAI-ARIA tree view over a read-only hierarchy projection.
 *
 * ## Selection contract (for lanes 3/4)
 *
 * ```ts
 * type onSelect = (nodeId: string) => void;
 * ```
 *
 * - Invoked exactly once per user selection gesture (pointer click, or
 *   keyboard activation: Enter/Space on the focused row, plus ArrowRight on
 *   a leaf — per WAI-ARIA tree pattern, right-arrow on a closed branch only
 *   expands and does NOT select).
 * - `nodeId` is the `NavNode.id` of the clicked/focused node, verbatim.
 *   For the fixture these are stable, deterministic path strings
 *   (e.g. `con-03/sq-01/sv-042/pl-0037`).
 * - The navigator holds NO selection state itself (fully controlled):
 *   pass back the selected id via the `selectedId` prop. A `selectedId`
 *   not present in the visible tree is ignored until it scrolls into view.
 * - The navigator never mutates the tree — read-only projection; there are
 *   no rename/delete affordances and none can be added via this component.
 *
 * ## Behavior
 * - `role="tree"` container, rows carry `role="treeitem"` with
 *   `aria-level` / `aria-expanded` / `aria-selected` (flat-DOM variant for
 *   virtualization; see TreeNode).
 * - Keyboard: ↑/↓ move roving focus, → expand or select, ← collapse or
 *   ascend, Home/End, Enter/Space select, printable characters run
 *   typeahead over visible labels.
 * - Virtualization: fixed 28px rows, windowed by scrollTop; lazy nodes
 *   materialize children on first expand only.
 *
 * @example
 * <TreeNavigator
 *   roots={FIXTURE_ROOT}
 *   selectedId={sel}
 *   onSelect={(id) => setSel(id)}
 * />
 */

import React, {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {
  childrenOf,
  flattenVisible,
  isExpandable,
  type NavNode,
} from '../../lib/navigator/tree-model';
import { ROW_HEIGHT, TreeNode } from './TreeNode';
import styles from './TreeNavigator.module.css';

export interface TreeNavigatorProps {
  /** Root nodes (read-only projection; never mutated). */
  roots: readonly NavNode[];
  /** Currently selected node id (controlled). */
  selectedId: string | null;
  /** Selection callback — see the module TSDoc for the full contract. */
  onSelect: (nodeId: string) => void;
  /** Viewport height in px. Defaults to 480. */
  height?: number;
  /** Extra rows rendered above/below the viewport window. */
  overscan?: number;
}

const TYPEAHEAD_RESET_MS = 500;

export function TreeNavigator({
  roots,
  selectedId,
  onSelect,
  height = 480,
  overscan = 10,
}: TreeNavigatorProps): React.ReactElement {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(() => new Set());
  const [scrollTop, setScrollTop] = useState(0);
  const [focusIndex, setFocusIndex] = useState(0);
  const [focusedId, setFocusedId] = useState<string | null>(null);
  const typeahead = useRef<{ buf: string; at: number }>({ buf: '', at: 0 });

  // Materialize lazy children for every currently expanded node, memoized on
  // `expanded` so flatten runs only when expansion or roots change.
  const rows = useMemo(() => {
    // Touch children of expanded nodes to force lazy synthesis before flatten.
    expanded.forEach((id) => {
      const found = findNode(roots, id);
      if (found) childrenOf(found);
    });
    return flattenVisible(roots, expanded);
  }, [roots, expanded]);

  const toggle = useCallback((id: string): void => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(id)) {
        next.delete(id);
      } else {
        next.add(id);
      }
      return next;
    });
  }, []);

  const selectAndFocus = useCallback(
    (index: number, alsoSelect: boolean): void => {
      const clamped = Math.max(0, Math.min(rows.length - 1, index));
      setFocusIndex(clamped);
      setFocusedId(rows[clamped]?.node.id ?? null);
      if (alsoSelect && rows[clamped]) onSelect(rows[clamped].node.id);
    },
    [rows, onSelect],
  );

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLDivElement>): void => {
      if (rows.length === 0) return;
      const current = rows[Math.max(0, Math.min(focusIndex, rows.length - 1))];
      switch (e.key) {
        case 'ArrowDown':
          e.preventDefault();
          selectAndFocus(focusIndex + 1, false);
          return;
        case 'ArrowUp':
          e.preventDefault();
          selectAndFocus(focusIndex - 1, false);
          return;
        case 'ArrowRight':
          e.preventDefault();
          if (isExpandable(current.node)) {
            if (current.expanded) selectAndFocus(focusIndex + 1, false);
            else toggle(current.node.id);
          } else {
            // Leaf: right-arrow selects per tree-pattern convention.
            onSelect(current.node.id);
          }
          return;
        case 'ArrowLeft':
          e.preventDefault();
          if (isExpandable(current.node) && current.expanded) {
            toggle(current.node.id);
          } else if (current.depth > 0) {
            const parentId = nodeIdOfParent(rows, focusIndex);
            if (parentId !== null) {
              const pIdx = rows.findIndex((r) => r.node.id === parentId);
              if (pIdx >= 0) selectAndFocus(pIdx, false);
            }
          }
          return;
        case 'Home':
          e.preventDefault();
          selectAndFocus(0, false);
          return;
        case 'End':
          e.preventDefault();
          selectAndFocus(rows.length - 1, false);
          return;
        case 'Enter':
        case ' ':
          e.preventDefault();
          onSelect(current.node.id);
          return;
        default:
          if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
            e.preventDefault();
            const now = Date.now();
            const buf = now - typeahead.current.at > TYPEAHEAD_RESET_MS
              ? e.key.toLowerCase()
              : typeahead.current.buf + e.key.toLowerCase();
            typeahead.current = { buf, at: now };
            for (let step = 1; step <= rows.length; step++) {
              const idx = (focusIndex + step) % rows.length;
              if (rows[idx].node.label.toLowerCase().startsWith(buf)) {
                selectAndFocus(idx, false);
                return;
              }
            }
          }
      }
    },
    [rows, focusIndex, selectAndFocus, toggle, onSelect],
  );

  // Keep the focused row inside the virtual viewport on keyboard nav.
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const top = focusIndex * ROW_HEIGHT;
    if (top < el.scrollTop) el.scrollTop = top;
    else if (top + ROW_HEIGHT > el.scrollTop + height) {
      el.scrollTop = top + ROW_HEIGHT - height;
    }
  }, [focusIndex, height]);

  const first = Math.max(0, Math.floor(scrollTop / ROW_HEIGHT) - overscan);
  const last = Math.min(
    rows.length,
    Math.ceil((scrollTop + height) / ROW_HEIGHT) + overscan,
  );
  const visible = rows.slice(first, last);

  return (
    <div
      ref={containerRef}
      role="tree"
      aria-label="Sovereign hierarchy navigator"
      tabIndex={0}
      className={styles.tree}
      style={{ height }}
      onKeyDown={handleKeyDown}
      onScroll={(e) => setScrollTop(e.currentTarget.scrollTop)}
    >
      <div className={styles.spacer} style={{ height: rows.length * ROW_HEIGHT }}>
        {visible.map((row, i) => {
          const index = first + i;
          return (
            <TreeNode
              key={row.node.id}
              row={row}
              top={index * ROW_HEIGHT}
              selected={selectedId === row.node.id}
              focused={focusedId === row.node.id || (focusedId === null && index === focusIndex)}
              hasChildren={isExpandable(row.node)}
              onSelect={onSelect}
              onToggle={toggle}
            />
          );
        })}
      </div>
    </div>
  );
}

/** Depth-first search for a node by id (roots + lazily loaded levels). */
function findNode(roots: readonly NavNode[], id: string): NavNode | null {
  const stack = [...roots];
  while (stack.length > 0) {
    const n = stack.pop() as NavNode;
    if (n.id === id) return n;
    if (n.children !== undefined) stack.push(...n.children);
    // Do not descend into lazy nodes here — synthesis is driven by `expanded`
    // in the rows memo; ids on unmaterialized branches cannot be expanded yet.
  }
  return null;
}

/** Id of the nearest ancestor row above `index` in the flattened rows. */
function nodeIdOfParent(rows: readonly { node: NavNode; depth: number }[], index: number): string | null {
  const depth = rows[index]?.depth ?? 0;
  if (depth === 0) return null;
  for (let i = index - 1; i >= 0; i--) {
    if (rows[i].depth < depth) return rows[i].node.id;
  }
  return null;
}
