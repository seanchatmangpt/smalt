# ws-court-sweep-20261021

Context: solo · Date: 2026-10-21 · Lane: bench-runner (census only, no fixes)

Post-checkpoint health sweep of the Next.js workspace gates against
`/Users/sac/smalt` (canonical checkout).

## Per-stage table

| Stage | Command | Exit | Verdict |
|---|---|---|---|
| ws-lint | `just ws-lint` | 127 | FAIL — `sh: eslint: command not found` |
| ws-build | `just ws-build` (`npm run build`) | 127 | FAIL — `sh: next: command not found` |
| ws-court | `just ws-court` (e2e-court.mjs) | 1 | FAIL — 101 `# FAIL` lines, 2 SKIP (live leg, :3100 down) |

Court detail: first line is `[FAIL] lib typecheck`; every subsequent failure is
`Cannot find module '<outDir>/lib/....js'` from the court's compiled outDir
(`/Users/sac/.cache/tmp/ws12-court-r1MpZ2/lib-js`), i.e. the TypeScript compile
step produced nothing. One loud SKIP: live popcorn-iframe leg (no Next server on
:3100, ECONNREFUSED). One legit PASS survived: composition panel type-surface.

## Attribution

- **Classification: pre-existing environment, not in-flight lane edits.**
- Root cause: `workspace/node_modules` does not exist
  (`ls workspace/node_modules/.bin/eslint` → No such file or directory), so
  `eslint`, `next`, and `tsc` are all unresolvable. All 101 court import
  failures cascade from that single missing dependency tree (the court's
  tsc step cannot run without node_modules).
- `git status --porcelain workspace/` is empty — no lane is mid-edit in the
  workspace subtree; last workspace commit is c037acb.
- No fix applied (census-only mandate). Recovery path (not run): `npm ci` in
  `workspace/`.

## Standing

**SUSPECT** — gates are not executable in the current tree state; the sweep
exercises no real signal about workspace correctness. PASS cannot be claimed
and the failure is infrastructural (deps not installed), not a code defect
witnessed. Logs: `/tmp/ws-build-sweep.log`, `/tmp/ws-court-sweep.log`.

---

## ADDENDUM (2026-10-21, recovery lane — do not merge into census above)

Context: solo · Action taken: infrastructural fix only (`npm ci` in `workspace/`;
lockfile `workspace/package-lock.json` present, so `npm ci` used, not `npm install`).

Install tail:
```
added 453 packages, and audited 454 packages in 9s
5 high severity vulnerabilities   (audit-only; not gated by any of the three stages)
npm warn install-scripts 1 package has install scripts not yet covered by allowScripts:
  unrs-resolver@1.12.2
```

Per-stage re-run:

| Stage | Command | Exit | Verdict |
|---|---|---|---|
| ws-lint | `just ws-lint` | 0 | PASS — 0 errors, 28 warnings (unused-vars class only, incl. lib/smalt.ts:65 SMALT_EGRESS/assertLocalUrl) |
| ws-build | `just ws-build` | 0 | PASS — Next build clean, static+SSG+dynamic routes emitted, middleware present |
| ws-court | `just ws-court` | 0 | PASS — **PASS=52 FAIL=0 SKIP=2** |

Court SKIPs (both loud, neither new): composition panel DOM/Web-Serial rendering
(node-inexecutable, witnessed at type layer — tsc --strict clean); live popcorn
iframe leg (:3100 ECONNREFUSED — no Next server running, matches sweep finding).

Attribution confirmed: the original sweep's 101 court failures were 100%
infrastructural (missing node_modules); zero real code defects surfaced on
recovery. No code fixes were made this session.

## Standing

**Standing:** ALIVE — all three workspace gates green on the canonical checkout after
dependency restore. Supersedes the SUSPECT standing above, which described the
pre-`npm ci` state. Logs: this lane's stage outputs (tails quoted in tables above).
