/**
 * Tree model for the Sovereign Hierarchy Navigator.
 *
 * Read-only projection: nodes are plain data; this module never mutates a
 * node. Lazy children are synthesized through `lazyLoad` and memoized in a
 * module-level WeakMap so the node objects themselves stay immutable.
 *
 * Consumer contract (lanes 3/4):
 *   - Build `NavNode` trees from your domain data (or use
 *     `lib/navigator/fixtures.ts` for the 150k-scale synthetic fixture).
 *   - Render with `components/navigator/TreeNavigator.tsx` and receive
 *     `onSelect(nodeId)` callbacks (see TreeNavigator TSDoc for the exact
 *     contract).
 */

/** Depth-0 .. depth-3 kinds of the sovereign hierarchy. */
export type NodeKind = 'constellation' | 'squadron' | 'vehicle' | 'payload';

/** A single node in the hierarchy projection. */
export interface NavNode {
  /** Stable unique id. Selection callbacks surface this value verbatim. */
  readonly id: string;
  /** Display label. Also the target of typeahead matching. */
  readonly label: string;
  /** Hierarchy level discriminator. */
  readonly kind: NodeKind;
  /**
   * Declared child count. For lazy nodes this is known up front (cheap
   * aggregate) even though the children themselves are not materialized.
   */
  readonly declaredChildCount?: number;
  /** Eager children (small levels). Mutually exclusive with `lazyLoad`. */
  readonly children?: readonly NavNode[];
  /**
   * Lazy child synthesizer (large levels, e.g. 150k-scale payloads).
   * Invoked at most once per node; result memoized in a WeakMap.
   */
  readonly lazyLoad?: () => readonly NavNode[];
}

/** True when the node can be expanded (has or can synthesize children). */
export function isExpandable(node: NavNode): boolean {
  return (node.children !== undefined && node.children.length > 0) ||
    node.lazyLoad !== undefined;
}

const lazyCache = new WeakMap<NavNode, readonly NavNode[]>();

/**
 * Materialize a node's children. Eager children pass through; lazy children
 * are synthesized once and cached. Returns [] for leaves.
 */
export function childrenOf(node: NavNode): readonly NavNode[] {
  if (node.children !== undefined) return node.children;
  if (node.lazyLoad === undefined) return [];
  let kids = lazyCache.get(node);
  if (kids === undefined) {
    kids = node.lazyLoad();
    lazyCache.set(node, kids);
  }
  return kids;
}

/** A flattened, depth-annotated row for virtualized rendering. */
export interface FlatRow {
  readonly node: NavNode;
  readonly depth: number;
  readonly expanded: boolean;
}

/**
 * Depth-first flatten of the visible (expanded) subtree.
 * `expanded` is the set of currently expanded node ids; `lazyLoad` is NOT
 * triggered here — callers expand a node only after materializing children.
 */
export function flattenVisible(
  roots: readonly NavNode[],
  expanded: ReadonlySet<string>,
): FlatRow[] {
  const rows: FlatRow[] = [];
  const walk = (nodes: readonly NavNode[], depth: number): void => {
    for (const node of nodes) {
      const expandable = isExpandable(node);
      const isOpen = expandable && expanded.has(node.id);
      rows.push({ node, depth, expanded: isOpen });
      if (isOpen) walk(childrenOf(node), depth + 1);
    }
  };
  walk(roots, 0);
  return rows;
}

/**
 * Find the flattened index of a node id (for scroll-into-view / focus
 * management after programmatic selection).
 */
export function indexOfId(rows: readonly FlatRow[], id: string): number {
  return rows.findIndex((r) => r.node.id === id);
}
