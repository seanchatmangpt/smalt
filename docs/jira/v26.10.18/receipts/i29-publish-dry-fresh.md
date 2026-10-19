# i29 — Publish-gate dry run + generated-artifact freshness (post-0009df3)

Date: 2026-10-18. Subject: /Users/sac/smalt @ 0009df3 (branch main).
Scope: read-only dry run + check-form regen checks. No edits, no git.
Context: solo(just publish-dry; mix help smalt.gen; python3 scripts/gen_error_codes.py --check)

## Gate 1 — `just publish-dry`

Exit code: **0**.

```
== publish dry-run gate: /Users/sac/smalt ==

-- gate 1: mix hex.build -o /tmp/hex-publish-dry/smalt.tar
   PASS (tarball: 778752 bytes; log: /tmp/hex-publish-dry/smalt.tar.build.log)

-- gate 2: inner-tar key grep (pattern: signing.key|verifying.key|\.ggen|keys/)
   PASS (0 matches in contents.tar.gz listing)

-- gate 3: packaged-set leak grep (pattern: athena|/Users/sac)
   PASS (0 hits in packaged set at /tmp/hex-publish-dry/smalt.tar.unpacked)

-- gate 4: python3 scripts/gen_error_codes.py --check
   PASS (docs/ERROR_CODES.md up to date)

== summary ==
PASS [gate1 hex.build]  PASS [gate2 inner-tar keys]  PASS [gate3 leak grep]  PASS [gate4 error-codes]
publish released pending final court-x2 (rotation EXECUTED 2026-10-15)
```

Leak-grep hits: **0**. ERROR_CODES identity failures: **none**. All four sub-gates PASS.

## Gate 2 — generated-artifact freshness

- `mix smalt.gen`: no `--check` flag exists (`mix help smalt.gen` documents no check/dry-run
  mode; the task only regenerates, which would WRITE to `lib/smalt/*.ex`).
  **[SKIP] mix smalt.gen freshness — no check flag; running it would write generated
  artifacts, which the task forbids.** Replay identity remains fenced by the per-artifact
  byte-identical replay tests, not verified here.
- `gen-error-codes` check form (read from justfile:151-152 → `scripts/gen_error_codes.py`,
  check mode is `--check`): standalone run —

```
docs/ERROR_CODES.md up to date
EXIT=0
```

PASS. (Same check publish-dry gate 4 runs; confirmed independently.)

## Verdicts

| Gate | Verdict |
|---|---|
| publish-dry (hex.build tarball) | PASS |
| inner-tar key grep | PASS |
| packaged-set leak grep | PASS (0 hits) |
| ERROR_CODES identity (--check) | PASS |
| six-artifact regen freshness (mix smalt.gen) | [SKIP] no check flag exists; regen would write |

Standing: **PARTIAL_ALIVE** — publish gates green; artifact-freshness half verified
(ERROR_CODES yes, six-artifact regen skipped as write-only, deferred to replay-identity tests).
