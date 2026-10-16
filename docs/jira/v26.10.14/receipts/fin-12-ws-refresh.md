# Receipt: fin-12 workspace court + build refresh

Date: 2026-10-15
Subject: /Users/sac/smalt @ main (working tree, uncommitted finish-lane edits)
Re-witness of converged DoD-2 state (`receipts/dod-02-workspace.md`, 39/0) after all workspace lanes + finish lanes landed.

## 1. ws-court

Command: `just ws-court` (node workspace/scripts/e2e-court.mjs)

Tail of output:

```
[PASS] composition: panel component type-surface — tsc --strict --noEmit clean over components+app+lib
[SKIP] composition: panel rendering — DOM/Web Serial rendering is not executable in node — witnessed instead at the type layer below
[SKIP] live: ARM read-only probe — no smalt substrate on http://127.0.0.1:9443 (ECONNREFUSED) — live leg not run

# court verdict
# PASS=39 FAIL=0 SKIP=2
```

Verdict: **PASS=39 FAIL=0 SKIP=2** — identical to the DoD-2 converged state. Both SKIPs are pre-existing
environmental skips (DOM/Web Serial not executable in node; no live substrate listening on 127.0.0.1:9443),
unchanged from DoD-2.

## 2. ws-build

Command: `just ws-build`; exit code **0**.

```
✓ Generating static pages using 5 workers (4/4) in 209ms
Route (app)
┌ ○ /
├ ○ /_not-found
└ ○ /console
○  (Static)  prerendered as static content
```

Verdict: build succeeds; the `/console` route is present and prerendered as static content.

## 3. New-failure classification

None. Zero FAILs and build exit 0 — no mechanical fixes and no peer defects to report.

## Standing

ALIVE (re-witnessed on the current tree with all finish-lane edits present).
