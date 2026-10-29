# PAT-D — pattern-court browser tier (real headless-Chromium verification)

**Standing:** **PARTIAL_ALIVE** — browser tier ALIVE (4/4 client-only patterns PASS against the real wasm sieve + journal in real headless Chromium); the court exit remains 1 because the pre-existing static dom-lint rows for P1/P2/P6/P8/P10/P12 still FAIL (PAT-A's selector contract not yet fully landed on page.tsx — pre-existing, not session-introduced).
Context: solo

## What landed

`workspace/scripts/pattern-court.mjs` (PAT-D-owned) gained a browser tier:

- **Executable discovery** — same mechanism as `popcorn_demo/scripts/browser_smoke.mjs`: `CHROMIUM_PATH` env → `~/Library/Caches/ms-playwright/chromium_headless_shell-*` → `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`. Witnessed here: system Chrome (headless-shell cache lookup ran first; Chrome won only because the shell binary path layout differed).
- **Serving** — `next build` (freshness-gated on source mtimes vs `.next/BUILD_ID`) then `next start -p <random loopback port>`, 4-attempt collision retry, 30s bounded readiness poll on `GET /terminal`. No `output:'export'` exists in `next.config.mjs`, so a real `next start` server is used; the page under test is fully client-side.
- **Real verdicts (per-pattern, witnessed output)**:
  - **P1 Ontological Airlock — PASS (browser)**: admit → `COMMITTED_LOCAL`, seq 0→1. Real chain: React page → law-worker-bridge → graphlaw.wasm sieve (real SHACL over the payload) → local journal append.
  - **P2 Visible Andon Cord — PASS (browser)**: SHACL-violating payload (`<urn:x> <urn:y> <urn:z> .` vs the minCount-1 reticle) → `role="alert"` with `data-andon-rule="non-conformant: <…MinCountConstraintComponent> at <urn:s>"`, status `HALTED_BY_SIEVE`, **seq unchanged**.
  - **P3 Monotonic Turnstile — PASS (browser)**: 50 sequential admits, seq strictly +1 each (3..52), no gaps, no regressions.
  - **P6 Bounded Arena — PASS (browser)**: 17 MiB payload → `ALLOC_CAP_EXCEEDED` andon, seq unchanged, then a post-cap admit commits (seq 2) — pinned worker survived the cap refusal.
  - **P4/P5/P9 stay typed SKIP** (SYNC-1 server / reload-rehydrate leg) — loud, contract reasons unchanged.

## Defect found and fixed by this tier (compile-freeze unblock, disclosed)

`workspace/workers/law-reticle.worker.ts:102` — WASI unlinked-imports check used
`n.slice(24)` but `"wasi_snapshot_preview1."` is 23 chars, so every import name was
compared truncated (`"andom_get"` vs provided `"random_get"`) and the guard claimed
every import unlinked: the sieve could never boot in ANY runtime — the plain-mjs
tier could never see this because it never ran the worker. One-byte fix
(`slice(24)` → `slice(23)`) applied under the compile-freeze unblock law; disclosed
here. Non-vacuity: court run BEFORE the fix produced 4 honest browser FAILs citing
`law worker INIT failed: unlinked WASI imports: …random_get…`; run AFTER produced
4/4 PASS. tsc --noEmit clean post-fix.

## Exits

- `node scripts/pattern-court.mjs` → **exit 1** (6 FAIL = pre-existing dom-lint
  contract gaps; browser rows 4/4 PASS). Totals: 7 PASS / 3 SKIP / 6 FAIL.
- Court wall time **15.6s** (budget <90s). Ephemeral loopback port
  (33448 witnessed), server SIGKILLed in `finally`, browser closed.
- No fixed sleeps: bounded polls only (`poll()` deadline helper; playwright
  `waitForFunction`/`waitForSelector` timeouts).

## Falsifier / boundary

- If PAT-A's selectors land and the dom-lint rows flip, court exit goes 0 with the
  same browser tier — that flip is PAT-A's receipt to carry.
- P2's dom-lint FAIL is structural: the alert banner emits from
  `lib/engine/useAndon.tsx`, but the lint greps only `app/terminal/page.tsx`; the
  live browser tier proves the selector IS on the rendered DOM. Registering this
  as a lint-surface gap for PAT-A, not a browser-tier defect.
- P1/P3/P6 browser checks FAIL honestly if run before PAT-A's page lands the
  `data-action="admit"` / payload-input / frame-log selectors (they exist today).

## Replay

```bash
cd /Users/sac/smalt/workspace && node scripts/pattern-court.mjs; echo "EXIT=$?"
```
