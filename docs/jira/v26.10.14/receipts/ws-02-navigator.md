# WS-02 Receipt — Sovereign Hierarchy Navigator

- **Lane**: WS-2
- **Date**: 2026-10-15
- **Scope discipline**: touched ONLY lane-owned paths (`workspace/components/navigator/`, `workspace/lib/navigator/`). WS-1 files (package.json, next.config, tsconfig, app/*) untouched. Temp verification scaffolding (`tsconfig.check.json`, `types/check-shims.d.ts`) created and deleted after use.

## Files built

| Path (absolute) | Purpose |
|---|---|
| `/Users/sac/smalt/workspace/lib/navigator/tree-model.ts` | Read-only `NavNode` model (eager `children` xor lazy `lazyLoad`), WeakMap-memoized lazy materialization via `childrenOf`, `flattenVisible`, `isExpandable`, `indexOfId`. Nodes never mutated. |
| `/Users/sac/smalt/workspace/lib/navigator/fixtures.ts` | Generated (not hand-listed) Constellation → Orbital Squadron → Space Vehicle → Sensor Payload fixture: 12 constellations, 3–6 squadrons each, 16–63 vehicles/squadron, 24–143 payloads/vehicle; all counts and labels derived from a string-hash-seeded mulberry32 PRNG; vehicles and payloads materialize lazily on first expand; deterministic. `DECLARED_ENTITY_SCALE = 150_000`. |
| `/Users/sac/smalt/workspace/components/navigator/TreeNavigator.tsx` | `'use client'` tree component: `role="tree"`, windowed virtualization (28px rows, overscan), roving-focus keyboard nav (↑/↓/←/→/Home/End/Enter/Space), typeahead over visible labels with 500 ms reset, lazy child synthesis on expand, scroll-into-view sync. Module TSDoc documents the selection contract. |
| `/Users/sac/smalt/workspace/components/navigator/TreeNode.tsx` | Windowed row: `role="treeitem"` with `aria-level` / `aria-expanded` / `aria-selected` (flat-DOM WAI-ARIA variant required by virtualization). Exports `ROW_HEIGHT`. |
| `/Users/sac/smalt/workspace/components/navigator/TreeNavigator.module.css` | CSS module styling (tree, spacer, row, selected/focused/hover states, twisty, badge). |

## onSelect contract (verbatim from TreeNavigator TSDoc)

```ts
type onSelect = (nodeId: string) => void;
```

- Invoked exactly once per selection gesture: pointer click on a row, or
  keyboard Enter/Space on the focused row, or ArrowRight on a leaf (per
  WAI-ARIA tree pattern; ArrowRight on a closed branch only expands).
- `nodeId` is the `NavNode.id` of the selected node, verbatim (stable,
  deterministic path strings in the fixture, e.g. `con-03/sq-01/sv-042/pl-0037`).
- Fully controlled: the navigator holds no selection state; consumers pass
  the selected id back via the `selectedId` prop. Unknown/hidden selected
  ids are simply unhighlighted until visible.
- Read-only projection: no mutation affordances (rename/delete structurally
  absent); the component never mutates the node tree.

## Verification

- Command: `npx tsc -p tsconfig.check.json --noEmit` (temporary strict
  tsconfig, `jsx: react-jsx`, `moduleResolution: bundler`, CSS-module shim)
  while WS-1's tsconfig was absent → **exit 0**.
- WS-1's `tsconfig.json` landed mid-run; re-ran the real gate:
  `npx tsc --noEmit` filtered to `navigator` paths → **0 errors**.
  Residual project errors are confined to `lib/atomvm/etf.ts`
  (another lane's path; pre-existing relative to this lane, not introduced
  by WS-2, not repaired per lane ownership).
- File existence confirmed on disk post-write (ls of both navigator dirs).

## Standing

ALIVE for lane scope: files compiled clean under the project's own
TypeScript gate on the exact bytes now on disk. Untested at runtime
(no browser/dev-server run this lane); composition and runtime behavior are
the integration lane's surface.
