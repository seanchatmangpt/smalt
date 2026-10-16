# Smalt Sovereign Next.js Workspace

Air-gapped Fortune-5 evaluation console for the **local smalt emulator**. Zero
cloud, zero athena, zero external network at runtime. Owned by lane WS-1;
other WS lanes add features in disjoint paths below.

## Layout conventions (WS lanes: read before writing)

```
workspace/
  app/                 # Next.js App Router pages/layouts (route = folder)
    layout.tsx         # root layout (WS-1 owned — do not edit; nest instead)
    page.tsx           # root page (WS-1 owned — coordinate before changing)
    globals.css        # tailwind entry (WS-1 owned)
  components/          # React components, one file per component, PascalCase
  lib/                 # non-component TS modules, kebab-case
    smalt.ts           # air-gap fetch helpers — ALL networking goes here
    types.ts           # shared types contract — DO NOT EDIT (see below)
  package.json         # WS-1 owned
```

- Your page route: `app/<your-feature>/page.tsx`. Do not edit `app/layout.tsx`
  or `app/globals.css` without coordinator sign-off.
- Components: `components/<Feature>Thing.tsx`, default-export, server component
  by default; add `"use client"` only when you need browser APIs (Web Serial,
  wasm, interactivity).
- One lane = disjoint paths. Never touch another lane's files.

## Shared types contract

`lib/types.ts` is the cross-lane vocabulary (`SmaltResponse<T>`,
`SmaltResource`, `CopilotProposal`, `SerialBridgeStatus`, `WasmModuleState`,
`ResourceState`). **Do not edit it.** Add your own types in a sibling file
(`lib/types.<domain>.ts`) and extend the base interfaces there.

## Networking / air-gap invariant (lint-enforced)

The console may contact **only** the local smalt emulator:

- `NEXT_PUBLIC_SMALT_ARM` (default `http://127.0.0.1:9443`) — ARM gateway
- `NEXT_PUBLIC_SMALT_EGRESS` (default `http://127.0.0.1:8443`) — egress router

Rules, mechanically enforced by `eslint.config.mjs`:

1. **No URL string literals in `fetch()`** — build URLs from `SMALT_ARM` /
   `SMALT_EGRESS` via `smaltFetch()` in `lib/smalt.ts`.
2. No `XMLHttpRequest`, no http-client imports (`axios`, `got`, `node-fetch`,
   `undici`, ...).
3. `lib/smalt.ts#assertLocalUrl` rejects any non-localhost host at runtime.

## Stack notes

- Next.js 16 (App Router, TS strict), React 19, Tailwind CSS **v4**
  (CSS-first: no `tailwind.config.js`; theme tokens live in `globals.css` as
  CSS custom properties, PostCSS plugin is `@tailwindcss/postcss`).
- Azure SDKs (`@azure/arm-resources`, `@azure/identity`, `@azure/storage-blob`,
  `@azure/cosmos`, `@azure/service-bus`, `@azure/event-hubs`,
  `@azure/keyvault-keys`, `@azure/eventgrid`) are preinstalled for the data
  lanes — they must be pointed at the emulator endpoints, never *.azure.com.
- `@/*` path alias maps to `workspace/` root.

## Commands

```
npm run dev     # next dev
npm run build   # next build  (gate: must pass)
npm run lint    # eslint      (gate: must pass)
```
