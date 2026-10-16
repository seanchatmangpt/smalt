'use client';

/**
 * N-1 grid bench page — 10,000-row virtualized tabular grid with hierarchical
 * rollups, rendered from deterministic generated fixture data (same seed on
 * server and client so SSR markup and hydration agree).
 *
 * Windowing follows the TreeNavigator pattern (fixed 28px rows, scrollTop
 * window, overscan). No new runtime deps.
 *
 * Bench hooks (window.__bench) are mounted only here, only for the N-1 lane:
 * - ready / hydrated markers for the driver
 * - applyPatches(n): n leaf-value mutations through the page's own state
 *   setter, each propagated into 2 ancestor rollups (real re-render work)
 * - scrollBurst(seconds, rowsPerSec): programmatic scroll driving row churn
 */

import React, {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';

const ROWS = 10_000;
const ROW_HEIGHT = 28;
const VIEWPORT = 600;
const OVERSCAN = 10;

// ---------------------------------------------------------------------------
// Deterministic fixture (mulberry32 — identical server/client)
// ---------------------------------------------------------------------------

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

interface GridRow {
  id: string;
  label: string;
  /** 0 = group, 1 = subgroup, 2 = leaf. */
  depth: 0 | 1 | 2;
  /** Leaf value; groups carry subtree rollup sums. */
  value: number;
  /** Second metric column. */
  count: number;
  /** Subtree leaf count (groups) or 1 (leaves). */
  leaves: number;
}

function buildRows(): GridRow[] {
  const rng = mulberry32(0x5eed);
  const rows: GridRow[] = [];
  let i = 0;
  while (i < ROWS) {
    const gid = `g${String(i).padStart(5, '0')}`;
    rows.push({ id: gid, label: `group-${gid}`, depth: 0, value: 0, count: 0, leaves: 0 });
    i++;
    const subgroups = 2 + Math.floor(rng() * 3);
    for (let s = 0; s < subgroups && i < ROWS; s++) {
      const sid = `s${String(i).padStart(5, '0')}`;
      rows.push({ id: sid, label: `sub-${sid}`, depth: 1, value: 0, count: 0, leaves: 0 });
      i++;
      const leaves = 3 + Math.floor(rng() * 5);
      for (let l = 0; l < leaves && i < ROWS; l++) {
        const lid = `l${String(i).padStart(5, '0')}`;
        rows.push({
          id: lid,
          label: `leaf-${lid}`,
          depth: 2,
          value: Math.floor(rng() * 10_000) / 10,
          count: 1 + Math.floor(rng() * 90),
          leaves: 1,
        });
        i++;
      }
    }
  }
  // Exact hierarchical rollups: each leaf accumulates into the nearest
  // preceding subgroup and group rows (leaves are contiguous after their
  // ancestors in this fixture layout).
  let sub = -1;
  let grp = -1;
  for (let k = 0; k < rows.length; k++) {
    const r = rows[k];
    if (r.depth === 0) {
      grp = k;
    } else if (r.depth === 1) {
      sub = k;
    } else {
      if (sub >= 0) {
        rows[sub].value += r.value;
        rows[sub].count += r.count;
        rows[sub].leaves += 1;
      }
      if (grp >= 0) {
        rows[grp].value += r.value;
        rows[grp].count += r.count;
        rows[grp].leaves += 1;
      }
    }
  }
  return rows;
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

export default function BenchGridPage(): React.ReactElement {
  const initialRows = useMemo(() => buildRows(), []);
  const [rows, setRows] = useState<GridRow[]>(initialRows);
  const [scrollTop, setScrollTop] = useState(0);
  const [revision, setRevision] = useState(0);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const burstRaf = useRef<number>(0);

  const rowsRef = useRef(rows);
  rowsRef.current = rows;

  // -- bench hooks ----------------------------------------------------------
  useEffect(() => {
    performance.mark('smalt-bench:hydrated');
    const bench = {
      ready: true as boolean,
      hydrated: false as boolean,
      patches: 0,
      applyPatches(n: number): number {
        let applied = 0;
        setRows((prev) => {
          if (prev.length === 0) return prev;
          const next = prev.slice();
          for (let p = 0; p < n; p++) {
            // Patch a random leaf; propagate into its ancestors.
            let idx = 1 + Math.floor(Math.random() * (next.length - 1));
            while (next[idx].depth !== 2) idx = 1 + ((idx + 1) % next.length);
            const delta = Math.round((Math.random() - 0.5) * 40) / 10;
            next[idx] = {
              ...next[idx],
              value: next[idx].value + delta,
              count: next[idx].count + 1,
            };
            // Ancestor propagation: walk back to nearest depth-1 then depth-0.
            let a = idx - 1;
            while (a >= 0 && next[a].depth !== 1) a--;
            if (a >= 0) next[a] = { ...next[a], value: next[a].value + delta, count: next[a].count + 1 };
            let g = a - 1;
            while (g >= 0 && next[g].depth !== 0) g--;
            if (g >= 0) next[g] = { ...next[g], value: next[g].value + delta, count: next[g].count + 1 };
            applied++;
          }
          return next;
        });
        setRevision((r) => r + 1);
        bench.patches += n;
        return applied;
      },
      scrollBurst(seconds: number, rowsPerSec: number): void {
        const px = rowsPerSec * ROW_HEIGHT;
        const start = performance.now();
        const step = (): void => {
          const el = containerRef.current;
          if (!el) return;
          const elapsed = (performance.now() - start) / 1000;
          if (elapsed >= seconds) {
            el.scrollTop = 0;
            setScrollTop(0);
            return;
          }
          const target = (elapsed * px) % (rowsRef.current.length * ROW_HEIGHT - VIEWPORT);
          el.scrollTop = target;
          setScrollTop(target);
          burstRaf.current = requestAnimationFrame(step);
        };
        burstRaf.current = requestAnimationFrame(step);
      },
      stopBurst(): void {
        cancelAnimationFrame(burstRaf.current);
      },
    };
    const w = window as unknown as Record<string, unknown>;
    w.__bench = bench;
    // Hydrated flag flips after the first paint following effect attach.
    requestAnimationFrame(() => {
      bench.hydrated = true;
    });
    return () => {
      bench.stopBurst();
      delete w.__bench;
    };
  }, []);

  // -- windowing (TreeNavigator pattern) ------------------------------------
  const first = Math.max(0, Math.floor(scrollTop / ROW_HEIGHT) - OVERSCAN);
  const last = Math.min(rows.length, Math.ceil((scrollTop + VIEWPORT) / ROW_HEIGHT) + OVERSCAN);
  const visible = rows.slice(first, last);

  const handleScroll = useCallback((e: React.UIEvent<HTMLDivElement>): void => {
    setScrollTop(e.currentTarget.scrollTop);
  }, []);

  return (
    <div style={{ padding: 16, fontFamily: 'monospace' }}>
      <h1 style={{ fontSize: 16, margin: '0 0 8px 0' }}>N-1 Grid Bench — 10k rows</h1>
      <div data-testid="bench-status">
        rev={revision} rows={rows.length} window=[{first}..{last})
      </div>
      <div
        ref={containerRef}
        role="grid"
        aria-label="Bench grid"
        style={{ height: VIEWPORT, overflowY: 'auto', border: '1px solid #888' }}
        onScroll={handleScroll}
      >
        <div style={{ height: rows.length * ROW_HEIGHT, position: 'relative' }}>
          {visible.map((row, i) => {
            const index = first + i;
            return (
              <div
                key={row.id}
                role="row"
                data-row={row.id}
                style={{
                  position: 'absolute',
                  top: index * ROW_HEIGHT,
                  height: ROW_HEIGHT,
                  left: 0,
                  right: 0,
                  display: 'flex',
                  alignItems: 'center',
                  paddingLeft: row.depth * 16 + 4,
                  borderBottom: '1px solid #ddd',
                  boxSizing: 'border-box',
                  whiteSpace: 'nowrap',
                }}
              >
                <span style={{ width: 220 }}>{row.label}</span>
                <span style={{ width: 120, textAlign: 'right' }}>{row.value.toFixed(1)}</span>
                <span style={{ width: 80, textAlign: 'right' }}>{row.count}</span>
                <span style={{ width: 80, textAlign: 'right' }}>{row.leaves}</span>
                <span style={{ color: '#666' }}>{row.depth === 2 ? 'leaf' : `rollup d${row.depth}`}</span>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
