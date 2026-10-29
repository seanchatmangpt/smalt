# BROWSER-COURT-PATTERNS

Status: PARTIAL_ALIVE (pattern consolidated from three witnessed instances;
each instance's standing is its own receipt's)
Context: solo
Date: 20261022T1250Z

Three independent lanes converged on the same headless-Chromium witnessing
pattern in v26.10.22. This doc records it once so the fourth court is
assembled, not reinvented. Every claim below cites a receipt; nothing here is
operator-asserted.

## Instances

- `popcorn_demo/scripts/browser_smoke.mjs` — receipts: `bk-popcorn-live.md`
  (live leg + exit contract), `bkskipport-fetch-ports.md` (SMOKE legs).
  Surface: in-browser wasm-BEAM Transport.Fetch over the real smalt wire.
- `popcorn_demo/scripts/bkskipport_witness.sh` — receipt:
  `bkskipport-fetch-ports.md`. Surface: atomic boot+seed+smoke driver.
- `workspace/scripts/weblocks-browser-court.mjs` — receipt:
  `bkwl-browser-witness.md`. Surface: native `navigator.locks` cross-tab
  lease semantics.

## Pattern anatomy

1. **Transpile the real modules with the project's own toolchain.**
   `weblocks-browser-court.mjs` transpiles the real engine modules
   (`useWebLocks.ts`, `tab-lease.ts`) with the workspace's own `tsc`
   (`typescript.transpileModule`); `browser_smoke.mjs` serves the cooked wasm
   bundle from `public/out` (BK-POPCORN: "bundle is cooked code — the wasm
   runs cooked live.ex; host-only verification is not a browser witness").

2. **Serve with COOP/COEP headers.** Both mjs courts set
   `cross-origin-opener-policy: same-origin` and
   `cross-origin-embedder-policy: require-corp` on every response — required
   for SharedArrayBuffer-class wasm execution and origin-keyed lock managers
   (witnessed in both receipts' court output).

3. **Serve on an ephemeral loopback port.** Both courts bind `127.0.0.1:0`
   and print the resolved port (`serving ... on http://127.0.0.1:54437`,
   BK-WLB receipt). No fixed ports, no collision with lane port law.

4. **Headless Chromium with a typed resolution ladder.** Order (browser_smoke.mjs):
   `CHROMIUM_PATH` env override → newest `chromium_headless_shell-*` under
   `~/Library/Caches/ms-playwright` → system Chrome at
   `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`. If none,
   loud exit 1 with the `npx playwright install` hint. BK-WLB witnessed the
   system-Chrome arm (playwright headless-shell cache path was empty on the
   box).

5. **Exit contract 0/1/3, SKIP is loud and typed.**
   - `0` all legs green; `1` any assertion failed (fail-closed);
     `3` typed SKIP — a missing capability types an honest UNKNOWN, never a
     fake pass (weblocks court: browser without `navigator.locks`;
     browser_smoke: `live=SKIP(substrate-down:...)`).
   - `SMOKE_ALLOW_OFFLINE=1` downgrades a substrate-down 3 to 0 while the
     loud SKIP fragment still prints (BK-POPCORN receipt, falsifier rows 1-2).
   - The gate keys on the `live=` fragment: when live SKIPPED, other legs'
     `=FAIL` fragments are substrate-down artifacts and ride visibly in the
     printed receipt; when `live=OK`, any `=FAIL` still forces 1 (BK-POPCORN
     deviation fix 2).

6. **Atomicity driver for flaky boot windows.**
   `bkskipport_witness.sh` wraps boot+seed+smoke in one flock'd script
   because canonical-port beams were being reaped by concurrent lanes'
   sweeps between separate commands (BK-SKIPPORT receipt, "Why atomic"). It
   polls the real observable (`curl /metadata/endpoints`, bounded 60x2s,
   `# SLEEP-CLASS: POLL-STEP`) and exits 2 on `SUBSTRATE-BOOT-FAIL` —
   consistent with the repo's exit-code contract for self-booting harnesses.

## Witnessed laws

- **Native-API-first, no shim in the browser.** The weblocks court asserts
  `navigator.locks.request` repr is `function request() { [native code] }`
  before any leg runs (BK-WLB, B2). Where node has no Web Locks, the node
  court keeps a FIFO-mutex shim (BK-119B) — but the *browser* court replaces
  it with the real API; a shim never crosses into a browser witness.
- **Cooked code, not host code.** The wasm witness runs the cooked bundle;
  host-only verification (mix test) is a separate, weaker claim (BK-POPCORN:
  "host-only verification is not a browser witness").
- **Shared BrowserContext for cross-tab semantics.** Playwright's
  `browser.newPage()` mints an ISOLATED context per page: BK-WLB witnessed
  two `newPage()` pages each holding the same lock exclusively with distinct
  clientIds. The court uses ONE shared `BrowserContext` with two pages; only
  there does Web Locks bind per origin. This is the load-bearing harness law
  for any cross-tab court.
- **Real collaborators end to end.** No mocks at any layer: real substrate
  (loopback, `:enforce` auth), real fetch, real browser (BK-SKIPPORT "What
  ran"; BK-WLB; BK-POPCORN).
- **Per-page contexts mint isolated identities** — the complement law: if a
  court needs isolation (fresh origin identity per leg), `browser.newPage()`
  is the tool; if it needs cross-tab semantics, one shared context is
  mandatory. Choose deliberately, the default is the wrong one for
  cross-tab (BK-WLB environment law).

## Escape hatches (typed SKIP conditions witnessed)

- Browser lacks `navigator.locks` → exit 3 SKIP (honest UNKNOWN; the node
  shim court remains witness). Receipt: `bkwl-browser-witness.md`.
- Substrate down — fetch "TypeError: Failed to fetch" family (the browser
  has no `econnrefused`) → `live=SKIP(substrate-down:...)`, exit 3, or 0
  with ALLOW_OFFLINE. Receipt: `bk-popcorn-live.md`.
- Capability class impossible in wasm BEAM (no sockets, no `:ssl`, no
  `:httpc`, no `:crypto` face) → PERMANENT-SKIP row with named reason.
  Receipt: `bkskipport-fetch-ports.md`.
- Surface absent (no ACR face; KD-101 airgap) → PERMANENT-SKIP row.
  Receipt: `bkskipport-fetch-ports.md`.
- CORS seed failure → leg SKIPs loudly
  (`blob=SKIP(cors-preflight-403:...)`); the seed is best-effort and never
  fakes a pass. Receipts: `bkskipport-fetch-ports.md` + the BK-91 comment
  in `browser_smoke.mjs`.
- Environment gone (dns zone deleted) → `UNSUPPORTED` typed verdict, loud,
  non-SKIP non-OK. Receipt: `bkskipport-fetch-ports.md`.

## Falsifiers and replay commands

- Weblocks browser court — replay:
  `cd workspace && node scripts/weblocks-browser-court.mjs`. Falsifier
  (flips to FAIL when): the lock name changes; standing stops being
  outcome-tracked; tab B starts while A holds; `query()` loses the held
  lock; the lease leaks past completion. (BK-WLB)
- Popcorn smoke (substrate up) — replay:
  `cd popcorn_demo && node scripts/browser_smoke.mjs`. Falsifier: the live
  fragment is not `live=OK(...)`; the SCVD gate types a failure.
  (BK-POPCORN)
- Popcorn smoke, offline branch — replay:
  `SMOKE_ALLOW_OFFLINE=1 node scripts/browser_smoke.mjs` (substrate down).
  Falsifier: nonzero exit while the loud SKIP prints. (BK-POPCORN)
- Atomic witness — replay:
  `bash popcorn_demo/scripts/bkskipport_witness.sh`. Falsifier: eg flips
  back to SKIP iff the `/topics` CORS face regresses; the permanent rows
  flip only if the named surface/transport lands in wasm. (BK-SKIPPORT)

## See Also

`receipts/bk-popcorn-live.md` · `receipts/bkskipport-fetch-ports.md` ·
`receipts/bkwl-browser-witness.md` · `docs/TESTBED.md` (exit-code contract) ·
`docs/NO_SLEEP_DOCTRINE.md` (poll-don't-sleep in drivers)
