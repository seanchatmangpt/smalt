# Receipt — W3C-E browser-runtime tranche (rows 7-11)

**Standing:** PARTIAL_ALIVE — rows 8/9/10 implemented + gated; rows 7/11 census + typed WO only
Context: solo
Date: 2026-10-21
Lane: W3C-E (workspace/ files + additive next.config edit; no engine-file collision with PAT-A/B — `law-worker-bridge.ts` untouched by this lane)

## Census (tranche rows 7-11)

| # | Standard | Census finding | Air-gap verdict |
|---|---|---|---|
| 7 | WebCrypto (SubtleCrypto, non-extractable keys) | `crypto.subtle` present in target browsers (secure contexts); `merkle.ts` already rides `subtle.digest` (documented sha256-chain deviation, kind tag `sha256-chain` on the wire). `generateKey(..., extractable:false)` is supported Chromium/Safari; SE-backed non-extractable keys (Touch ID / Secure Enclave) where the platform offers them. No signing keys exist in the journal path today. | Buildable once the receipt format absorbs a signature field — **seam, not built** |
| 8 | Web Locks | `navigator.locks` ships in Chromium 69+ and Safari 15.4+; workspace browser floor (Next 16 / React 19, evergreen Chromium) has it. Node 26 does not implement `navigator.locks` (getter-only `navigator` global, no locks) — courts run the typed fallback path plus a hand-written FIFO-mutex `LockManager`. | **Implemented** |
| 9 | Service Workers | `workspace` runs the Next **dev-server mode** (no `output:'export'`; `ws-build` emits `.next`, not `out/`). SW registration from `app/layout.tsx` via client component; scope `/`. `public/wasm/graphlaw.wasm` exists on disk (verified) and is served at `/wasm/graphlaw.wasm` — precache entry matches the real output path. | **Implemented** (precache list verified against `public/` on disk; `/` and `/console` are real routes in the ws-build route table) |
| 10 | COOP/COEP + manifest | Console is served by the Next dev/prod server; `next.config.mjs` already carries a `headers()` block — additive row added. No `output:'export'`, so `headers()` is live (no static-export block). | **Implemented** |
| 11 | WebAuthn L3 | Platform authenticator (Touch ID) present on this Mac for the operator. Registration requires a **server RP endpoint**: the challenge/registration ceremony is server-side and the public key must be stored as a `prov:Agent` in the identity graph. Loopback caveat: WebAuthn requires a secure context (loopback qualifies) but the RP ID must be a registrable domain — use the `localhost` origin, never a raw `127.0.0.1` IP origin (IP origins cannot be RP IDs). Bearer-JWT STS is the current identity surface. | **Census only — typed WO** |

## Implemented

### Row 8 — Web Locks master lease (`lawinput_wal_lock`)

- **`workspace/lib/engine/tab-lease.ts`** (new): `withWalLease(fn, opts)` around
  `navigator.locks.request("lawinput_wal_lock", …)`. Typed degradation: where
  `navigator.locks` is absent the body still runs and the result carries
  `mode: "fallback"` — the single-tab hazard stays loud, never a faked pass.
  Typed refusals: `LEASE_TIMEOUT` (bounded wait), `LEASE_ABORTED`,
  `LEASE_REFUSED`, `BODY_FAILED`.
- **`workspace/lib/engine/useJournal.ts`** (additive): `append()` and `sync()`
  (the drain) now ride the master lease; `unwrapLease()` flattens
  `WalLeaseResult<JournalResult<T>>` → `JournalResult<T>` mapping lease
  refusals to typed `STORE_FAILURE` so the existing error surface is unchanged.
- **Court `workspace/scripts/tab-lease-court.mjs`** (new): tsc-compiles
  tab-lease.ts to a temp dir, installs a hand-written FIFO-mutex LockManager
  (real degraded collaborator — `navigator.locks` does not exist in node;
  named exception per testing discipline, simple fake not a mock) and asserts
  end state:
  - fallback: body runs with `mode:"fallback"`, body failure → `BODY_FAILED`
  - exclusivity: two overlapping leases serialize (no interleaving) and the
    mode reads `web-locks`
  - a failing body releases the lock; the next holder acquires
  - held lease + `timeoutMs` refuses `LEASE_TIMEOUT` within budget
  - non-vacuity witness: before the fake honored the abort signal, this leg
    returned the body value through a held lease (`{"ok":true,"value":"never"}`)
    — the court flipped to REFUSE and only passed after the fake implemented
    the spec surface. The court can fail.

### Row 9 — Service worker

- **`workspace/public/sw.js`** (new): precache `/`, `/console`,
  `/wasm/graphlaw.wasm` (list verified against `public/` on disk and the
  ws-build route table); build-pinned cache `console-shell-v1`, activate
  purges stale caches; same-origin GET only (air-gap law); navigations
  network-first with cache fallback for offline cold boot; `/_next/static/`
  and the WASM artifact cache-first.
- **`workspace/components/sw-register.tsx`** (new) + one line in
  **`workspace/app/layout.tsx`**: best-effort registration of `/sw.js` on
  load; refusal logged, never a fake pass — offline capability simply is not
  armed without the SW.

### Row 10 — COOP/COEP + manifest

- **`workspace/next.config.mjs`** (additive): `COOP: same-origin` +
  `COEP: require-corp` on `/(.*)` — unlocks SharedArrayBuffer for zero-copy
  UI↔worker transfer; Spectre-class mitigation posture.
- **`workspace/public/manifest.webmanifest`** (new) + `metadata.manifest` in
  `app/layout.tsx`. `icons: []` honest-empty (no icon assets minted).

## Typed plan only (not built — seams named)

- **Row 7 WebCrypto signing**: signing needs the SYNC-1 receipt format to
  absorb a signature field (sign each WAL frame + Merkle root with a
  non-extractable key; signature rides the frame/receipt export). Building
  the signer without the format change would be a half-build. WO: extend the
  SYNC-1 receipt/frame schema with an optional signature field + court that a
  tampered signature refuses.
- **Row 11 WebAuthn**: needs an RP server endpoint on the identity plane
  (challenge + registration + `prov:Agent` public-key registration in the
  identity graph; credentials never transit the wire). WO: identity-plane RP
  endpoint; rp.id `localhost`, never the raw IP origin.

## Gates (real output, this session)

- `just ws-lint` → `0 errors, 38 warnings` (warnings pre-existing). One
  disclosed cross-lane fix under the compile-freeze SLA: the single lint
  error lived in `workspace/scripts/pattern-court.mjs` (another lane's
  in-flight file) — minimal fix (template-literal fetch URL → string
  concat, air-gap lint rule). Disclosed here; both lanes' receipts should
  name it.
- `just ws-build` → compiled successfully; full route table rendered
  (`/console` static, WASM artifact served from `public/`).
- `node scripts/tab-lease-court.mjs` → `# PASS: 7 / # FAIL: 0`.
- `just ws-court` → `# PASS=62 FAIL=0 SKIP=2` (skips loud: DOM rendering not
  node-executable; no Next server on :3100).
