# i29 — Push-readiness audit #3 (origin/main..main)

- **Date**: 2026-10-18
- **Subject**: HEAD `3cf366723131f1bc56e1db185863a80795605a14`, base `origin/main` (1eb89df)
Context: solo — single lane, read-only git + `just publish-dry`; no mutations, no push.

## Scope

24 commits unpushed (`git rev-list origin/main..main --count` → 24).

## Per-commit secret-pattern grep

Patterns: `BEGIN (RSA|EC|OPENSSH )?PRIVATE KEY`, `SECRET[A-Z_]*=<16+ chars>`,
`password=`, `AKIA…`, `ghp_…`, broad `-----BEGIN`, `.env.<ext>` references —
applied to each commit's full diff, excluding `docs/jira/*` per task spec.

| # | commit | verdict | note |
|---|--------|---------|------|
| 1 | d1298be | clean | |
| 2 | efc8d92 | clean | |
| 3 | 19a420a | clean | |
| 4 | d8fd6c3 | clean | |
| 5 | b9b9199 | clean | |
| 6 | 48304c1 | clean | |
| 7 | c1ca250 | clean | |
| 8 | f4f129f | clean | |
| 9 | 334f3f8 | clean | |
| 10 | 1339e05 | clean | |
| 11 | 4843bd0 | clean | |
| 12 | e916d76 | clean | |
| 13 | 1aab68d | clean | |
| 14 | 1aaed7c | clean | |
| 15 | 806d86e | clean | |
| 16 | 7a68cb0 | clean | |
| 17 | 4ed7ef5 | clean | |
| 18 | 8b7cbcd | clean | |
| 19 | 4106990 | 0 secrets | 5 pattern hits = FALSE POSITIVE: `SmaltTest.Env.put_restored` matches the `.env.<ext>` regex; no secret material |
| 20 | c2a304c | clean | |
| 21 | 9cbee40 | clean | |
| 22 | 286c35e | clean | |
| 23 | 34f2012 | clean | |
| 24 | 3cf3667 | clean | |

All 24 loop verdicts: clean, except #19 `4106990` (5 pattern hits, all the
documented false positive). No real secret material in any diff.

## Publish-dry gate at HEAD

```
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
EXIT=0
```

## Verdict

**READY** — 24/24 commit diffs free of secret material (one documented regex
false positive, no real hits); `just publish-dry` exit 0 at HEAD `3cf3667`.

Untracked/modified working-tree files (15 M + 3 ??) are NOT part of any
commit in `origin/main..main` and do not affect push readiness.
