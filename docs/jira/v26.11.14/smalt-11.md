# smalt-11 Shim courts for AWS SigV4 and GCP auth gates

Standing: UNVERIFIED

## Problem

/Users/sac/smalt/scripts/shim_court/ holds courts for arm, kafka, kv, ledger, sleep and others,
built on
`with_shim` in /Users/sac/smalt/scripts/shim_court/lib.sh (BASELINE sha, BEFORE, SHIM, AFTER,
RESTORE).
None targets /Users/sac/smalt/lib/smalt/aws/sigv4.ex, /Users/sac/smalt/lib/smalt/aws/s3_router.ex or
/Users/sac/smalt/lib/smalt/gcp/identity.ex. The 76 passing tests in /Users/sac/smalt/test/aws and
/Users/sac/smalt/test/gcp could pass
vacuously: nothing proves that weakening the SigV4 constant-time verify or the
router's service=s3 scope claim flips a test red.

## Acceptance

New /Users/sac/smalt/scripts/shim_court/sigv4_court.sh and gcp_auth_court.sh. Run
`just shim-court sigv4` and `just shim-court gcp_auth`: each prints BEFORE pass, SHIM
fail, AFTER pass-restored, RESTORE sha256 identical, exit 0. Self-check corrupts a
restore on a temp copy and the court exits 1.

## Falsifier

A shim (e.g. verify/3 always returning :ok) that leaves /Users/sac/smalt/test/aws green means the
court
cannot flip: report FAIL (VACUOUS), not skip.

## Owned files

/Users/sac/smalt/scripts/shim_court/sigv4_court.sh,
/Users/sac/smalt/scripts/shim_court/gcp_auth_court.sh,
/Users/sac/smalt/scripts/shim_court/README.md (rows only).

## Depends-on

smalt-09 (green baseline to shim against)

## Size

M

## References (path : LOC)

- /Users/sac/smalt/scripts/shim_court/lib.sh : 175 lines
- /Users/sac/smalt/scripts/shim_court/ : 64 files, 8468 lines total
- /Users/sac/smalt/scripts/shim_court/README.md : 77 lines
- /Users/sac/smalt/lib/smalt/aws/sigv4.ex : 126 lines
- /Users/sac/smalt/lib/smalt/aws/s3_router.ex : 140 lines
- /Users/sac/smalt/lib/smalt/gcp/identity.ex : 207 lines
- /Users/sac/smalt/test/aws/ : 7 files, 522 lines total
- /Users/sac/smalt/test/gcp/ : 9 files, 860 lines total
- /Users/sac/smalt/scripts/shim_court/sigv4_court.sh : NEW (0 lines, to be created; est. LOC: 90;
  basis: existing *_court.sh files in scripts/shim_court run 60-130 lines)
- /Users/sac/smalt/scripts/shim_court/gcp_auth_court.sh : NEW (0 lines, to be created; est. LOC: 90;
  basis: same basis as sigv4_court.sh)

## Result

Standing: UNVERIFIED (authored, never executed)

Files: /Users/sac/smalt/scripts/shim_court/sigv4_court.sh (~55 LOC, two legs: sigv4.ex, s3_router.ex),
/Users/sac/smalt/scripts/shim_court/gcp_auth_court.sh (~45 LOC),
/Users/sac/smalt/scripts/shim_court/README.md (+5 rows).
AFTER witness passes only if tests fail with real failures (not compile error); green-under-shim
exits 1 as VACUOUS. gcp shim uses JOSE.JWT.peek_payload; adjust if first run shows a compile error.
Courts need chmod +x (shell was hook-blocked); `just shim-court` uses `bash`, so not required.

Acceptance: cd /Users/sac/smalt && just shim-court sigv4 && just shim-court gcp_auth
