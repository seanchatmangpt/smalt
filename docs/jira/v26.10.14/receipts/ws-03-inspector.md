# WS-03 — Multi-Mode Resource Inspector

Lane: WS-3 · Repo: /Users/sac/smalt · Date: 2026-10-15 · Status: LANDED

## Files (disjoint lane paths only)

- `workspace/components/inspector/ResourceInspector.tsx`
- `workspace/components/inspector/JsonMode.tsx`
- `workspace/components/inspector/HexMode.tsx`
- `workspace/components/inspector/AttestationMode.tsx`
- `workspace/lib/inspector/encoding.ts`
- `workspace/tsconfig.check.json` (verification fallback; scaffold tsconfig not yet on disk)

Shared types are exported from `ResourceInspector.tsx` (no extra file, per "build only" list).

## What was built

- Three tabs: JSON telemetry manifest, raw hex payload, attestation digest view.
- ARIA tabs pattern: `role=tablist/tab/tabpanel`, `aria-selected`/`aria-controls`/
  `aria-labelledby`, roving tabindex, Left/Right/Home/End arrow-key nav.
- `encoding.ts`: 16-byte-per-row hex dump (offset | hex | ascii), non-printables
  rendered as `.`, UTF-8-safe decode via `TextDecoder(fatal:false)` (U+FFFD
  replacement, never throws), ETF magic-131 envelope recognition (structural
  decode deferred to ETF codec lane), stable JSON stringify fallback.
- `HexMode` renders Navigator-selected node payload bytes; object payloads are
  UTF-8-encoded for the byte view so hex and JSON tabs correspond.
- `AttestationMode` renders digest + validity badge from props only. Signature
  validation is WS-10's; absent `attestation` renders an honest
  "Unverified — no attestation record" state. No fabricated verdicts.

## Verification

```
$ cd /Users/sac/smalt/workspace && npx tsc --noEmit -p tsconfig.check.json
EXIT=0
```

Notes: strict mode; `@/*` path alias mapped to workspace root in the check
tsconfig. No styling framework committed by scaffold yet (empty `components/`),
so Tailwind utility classes used (tailwindcss 3.4 is in devDependencies);
WS-1 owns wiring `globals.css`/tailwind config.

## Props contract (integration)

```ts
interface InspectorNode {
  id: string;                                     // Navigator node id
  name: string;                                   // display name
  payload?: Uint8Array | Record<string, unknown>; // raw bytes OR manifest object
}
interface Attestation {
  digest: string;  // rendered verbatim, e.g. "sha256:…"
  valid: boolean;  // WS-10 verdict — presented, not computed
  signer?: string;
}
<ResourceInspector node={selectedNode} attestation={att?} />
```

## Falsifier

- Tabs fail arrow-key nav or expose all panels to AT → contract broken.
- Attestation tab renders a valid badge when `attestation` prop is absent → violation.
- Hex view emits control characters or throws on invalid UTF-8 → violation.

## Standing

ALIVE (type-check receipt only; no runtime render yet — app layout is WS-1's).
