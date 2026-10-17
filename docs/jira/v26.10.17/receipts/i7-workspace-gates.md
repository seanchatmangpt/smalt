# I7 — Workspace Gates (ws-lint / ws-build / ws-court)

Standing: **PASS** (all three gates green, exit 0 each)

- Lane: I7 of `docs/jira/v26.10.17/_LANES.md` (verify lane, lease: `workspace/`)
- Repo: `/Users/sac/smalt`, branch main, 2026-10-17 14:42 local
- Machine load at start: load average **9.57** (7.69, 7.09) — not quiet; noted per lane instruction. No failures attributable to contention: all three gates exited 0 on first post-install attempt.

## Environment note (pre-existing, disclosed)

`workspace/node_modules` was absent at lane start (fresh checkout state). `npm ci` ran
clean (453 packages, exit 0) before the gates. This is a per-machine install, not a
lane-introduced change to tracked files.

## 1. `just ws-lint` — exit 0

```
> eslint .
✖ 29 problems (0 errors, 29 warnings)
```

All 29 are `@typescript-eslint/no-unused-vars` warnings (underscore-prefixed params in
`lib/azure/*` adapters, unused imports in scripts/tests). 0 errors.

## 2. `just ws-build` — exit 0

```
✓ Compiled successfully
...
└ ƒ /process/api
ƒ Proxy (Middleware)
○  (Static)  prerendered as static content
●  (SSG)     prerendered as static HTML (uses generateStaticParams)
ƒ  (Dynamic) server-rendered on demand
```

Route table rendered; `git status` on `workspace/` remains clean (build artifacts
untracked/ignored).

## 3. `just ws-court` — exit 0

```
# court verdict
# PASS=50 FAIL=0 SKIP=2
# SKIP: composition: panel rendering: DOM/Web Serial rendering is not executable in node — witnessed instead at the type layer below
# SKIP: live: ARM read-only probe: no smalt substrate on http://127.0.0.1:9443 (ECONNREFUSED) — live leg not run
```

Datum drift vs task brief: the brief cited **PASS=42 FAIL=0 SKIP=1**. That figure is the
v26.10.16 standing datum (v26.10.16 `FINAL.md` line 49); the court suite has grown since
(7 new passing asserts, 1 new loud SKIP for the substrate-down live leg — no substrate was
running per lane instruction to run quiet). Both SKIPs are loud and reasoned, zero FAILs.
The 50/0/2 verdict is the fresh standing datum for this receipt.

## Summary

| gate | exit | result |
|---|---|---|
| ws-lint | 0 | 0 errors, 29 warnings (no-unused-vars only) |
| ws-build | 0 | compiled, all routes built |
| ws-court | 0 | PASS=50 FAIL=0 SKIP=2 (loud, reasoned skips) |
