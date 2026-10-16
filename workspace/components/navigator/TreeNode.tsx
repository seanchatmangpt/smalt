'use client';

/**
 * TreeNode — a single windowed row of the TreeNavigator.
 *
 * Internal component of the navigator; TreeNavigator owns state and keyboard
 * handling. Because the tree is virtualized, each rendered row is NOT a
 * WAI-ARIA `treeitem` container with a nested `group` — the flat row carries
 * `role="treeitem"` with `aria-level`, `aria-expanded`, and `aria-selected`
 * so the accessibility tree matches the WAI-ARIA tree pattern while only
 * visible rows exist in the DOM.
 */

import React from 'react';
import type { FlatRow } from '../../lib/navigator/tree-model';
import styles from './TreeNavigator.module.css';

export const ROW_HEIGHT = 28;

export interface TreeNodeProps {
  row: FlatRow;
  top: number;
  selected: boolean;
  focused: boolean;
  hasChildren: boolean;
  onSelect: (id: string) => void;
  onToggle: (id: string) => void;
}

export function TreeNode({
  row,
  top,
  selected,
  focused,
  hasChildren,
  onSelect,
  onToggle,
}: TreeNodeProps): React.ReactElement {
  const { node, depth, expanded } = row;
  const handleClick = (): void => {
    onSelect(node.id);
    if (hasChildren) onToggle(node.id);
  };
  return (
    <div
      role="treeitem"
      aria-level={depth + 1}
      aria-expanded={hasChildren ? expanded : undefined}
      aria-selected={selected}
      data-node-id={node.id}
      className={[
        styles.row,
        selected ? styles.rowSelected : '',
        focused ? styles.rowFocused : '',
        selected ? '' : styles.rowHover,
      ].filter(Boolean).join(' ')}
      style={{ top, height: ROW_HEIGHT, paddingLeft: depth * 18 + 8 }}
      onClick={handleClick}
    >
      <span className={styles.twisty} aria-hidden="true">
        {hasChildren ? (expanded ? '▾' : '▸') : '·'}
      </span>
      <span className={styles.label}>{node.label}</span>
      {node.declaredChildCount !== undefined && (
        <span className={styles.badge}>{node.declaredChildCount.toLocaleString('en-US')}</span>
      )}
    </div>
  );
}
