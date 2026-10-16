# WS-1 Scaffold Receipt — Smalt Sovereign Next.js Workspace

- Subject: /Users/sac/smalt/workspace (new Next.js 16 + React 19 + Tailwind v4 scaffold)
- Base: smalt main @ `3fc2543e53ef34df733c6aa2536429f4122cd143`
- Date: 2026-10-15T23:59:32Z
- Lane: WS-1 (scaffold owner). Not committed (per task).

## Owned artifacts (all present on disk)

- package.json, package-lock.json (npm-installed, lockfile committed to disk)
- next.config.mjs, tsconfig.json, postcss.config.mjs, eslint.config.mjs, .gitignore, .env.example
- app/layout.tsx, app/page.tsx, app/globals.css
- lib/smalt.ts (air-gap fetch helpers), lib/types.ts (shared types contract)
- README.md (lane conventions)

## Versions (resolved by npm, latest at install)

next 16.4.2, react 19.3.1, react-dom 19.3.1, typescript 6.0.3, tailwindcss 4.3.3,
eslint 9.39.5. Azure SDKs preinstalled: @azure/arm-resources 8.0.0,
@azure/identity 4.14.0, @azure/storage-blob 12.34.0, @azure/cosmos 4.10.1,
@azure/service-bus 7.10.0, @azure/event-hubs 6.0.4, @azure/keyvault-keys 4.10.2,
@azure/eventgrid 5.12.0.

## Verification ladder

1. `npm run build` (next build, whole tree incl. all WS lanes' files) — PASS.
   Tail:

```
┌ ○ /
└ ○ /_not-found
○  (Static)  prerendered as static content
```

2. `npm run lint` (eslint flat config) — PASS, 0 errors / 12 warnings
   (all warnings in non-WS-1 files: lib/azure, lib/serial, lib/serial, scripts/).

   ```
   ✖ 12 problems (0 errors, 12 warnings)
   ```

3. Positive control on air-gap lint rule (fired as designed, probe removed):

```
  1:7  error  Air-gap invariant: fetch() must not take a string literal URL. Use SMALT_ARM / SMALT_EGRESS from lib/smalt.ts (localhost only)  no-restricted bans
```

## Compile-freeze unblock fixes (disclosed, other lanes' files, minimal)

- lib/atomvm/etf.ts:120 — syntax error `EtfE rror` → `EtfError` (compile-abort).
- lib/atomvm/actor-host.ts — syntax errors: duplicated/garbled DeliveryEnvelope
  interfaces, `replies` undefined, `spawned? [`, double `break`, stray `...`
  method; fixed to single interface + single runTurn, Mailbox.push return,
  drain() SudoPid typo. One edit bounced on concurrent owner write; owner
  landed the remaining garbage mid-session and I re-fixed on the current file.
- lib/attestation/validator.ts:23-24 — `.ts` import extensions (TS5097) →
  extensionless.
- lib/azure/cosmos-manifest.ts — fetchAll(…args) arity (moved options into
  `query(spec, opts)`), upsert type annotation `ItemResponse<ItemDefinition>`
  (+import).
- lib/azure/sb-telemetry.ts — `Sender`/`Receiver` imports → `ServiceBusSender`/
  `ServiceBusReceiver` (v7 names); `m.complete` does not exist on
  `ServiceBusReceivedMessage` typings — type-level casts only, runtime witness
  preserved; implicit-any param typed.

## Gates that are UNKNOWN/remaining

- 12 lint warnings in other lanes' files (owners' cleanup, non-blocking).
- Runtime behavior against the live smalt emulator (ARM 9443 / egress 8443)
  not exercised here — that is the data lanes' courts.
- `next lint` was removed in Next 16; lint script = `eslint .` via flat config.

## Replay

```
cd /Users/sac/smalt/workspace
npm install
npm run build   # must exit 0
npm run lint    # must exit 0 (warnings allowed)
printf 'fetch("http://example.com/x");\n' > app/_probe.ts && npx eslint app/_probe.ts; rm app/_probe.ts  # air-gap rule fires
```
