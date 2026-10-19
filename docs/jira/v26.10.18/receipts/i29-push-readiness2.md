# i29-push-readiness2 — re-audit of the unpushed b9a6dc1 lineage

- Date: 2026-10-18, repo /Users/sac/smalt, branch main
- Range: `origin/main..main` = 12 commits, base 44b0859, HEAD b9a6dc1
- Method: per-commit `git diff-tree` file counts + secret-pattern grep on each
  full diff (`/Users/sac` literals outside docs/jira receipts, `PRIVATE KEY`
  blocks, `.env`-style `SECRET|PASSWORD|TOKEN|KEY=` literal assignments),
  file-scoped so hits are classified docs/jira vs elsewhere; then
  `just publish-dry` at HEAD.
- Context: solo(read-only audit, no mutations, no git state commands beyond
  log/diff-tree/show)

## Per-commit table

| commit | files | secret-pattern hits | classification |
|---|---|---|---|
| b9a6dc1 | 6 | 4 | all in docs/jira/v26.10.18/receipts/* — allowed class |
| 1a309e2 | 6 | 4 | docs/jira receipts (doctor-dod-gapcensus, sdk-smoke-deps) — allowed |
| acb820a | 2 | 1 | docs/jira receipt (midnight-map-refresh) — allowed |
| d8e5535 | 16 | 6 | docs/jira receipts x5 files — allowed |
| f56ee6b | 4 | 1 | docs/jira receipt (arg-route-family) — allowed |
| 84268de | 2 | 0 | clean |
| a8e8867 | 5 | 0 | clean |
| 0e5797c | 3 | 1 | docs/jira receipt (eg-gracefulstop-classify) — allowed |
| 25b844f | 3 | 1 | docs/jira receipt (leak-remediation) — allowed |
| 2106032 | 6 | 6 | docs/jira receipt (stress-real-fixes) — allowed |
| d6dbe67 | 2 | 1 | docs/jira receipt (court-rehearsal) — allowed |
| 9cf4e69 | 21 | 33 | docs/jira receipts x11 files — allowed |

Aggregate: 58 pattern hits, 58/58 inside `docs/jira/**` receipts (audit
path/name references), 0 outside, 0 `PRIVATE KEY` blocks, 0 `.env`-style
secret literals.

## publish-dry at HEAD b9a6dc1

```
$ just publish-dry
== publish dry-run gate: /Users/sac/smalt ==

-- gate 1: mix hex.build -o /tmp/hex-publish-dry/smalt.tar
   PASS (tarball: 793600 bytes; log: /tmp/hex-publish-dry/smalt.tar.build.log)

-- gate 2: inner-tar key grep (pattern: signing.key|verifying.key|\.ggen|keys/)
   PASS (0 matches in contents.tar.gz listing)

-- gate 3: packaged-set leak grep (pattern: athena|/Users/sac)
   PASS (0 hits in packaged set at /tmp/hex-publish-dry/smalt.tar.unpacked)

-- gate 4: python3 scripts/gen_error_codes.py --check
   PASS (docs/ERROR_CODES.md up to date)

== summary ==
PASS [gate1 hex.build]  PASS [gate2 inner-tar keys]  PASS [gate3 leak grep]  PASS [gate4 error-codes]
publish released pending final court-x2 (rotation EXECUTED 2026-10-15)
EXIT=0
```

## Verdict

**READY** — the 12-commit origin/main..main lineage is secret-clean under the
three patterns and `just publish-dry` exits 0 at HEAD b9a6dc1. Note (pre-existing,
not a blocker): the working tree carries uncommitted in-flight lane edits
(git status at audit time); they are outside the audited commit range and do
not ride the push.
