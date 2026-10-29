# BK-N2B — n2 harness auto-scrape of `$ACTION_ID_` (optional env, fail-closed)

**Standing:** **ALIVE**
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main)
Lane: BK-N2B
Parent: BK-BLD (`bkbld-buildid.md`), REGISTRY n2 ACTIVE-WITH-WITNESS row

## Change

`scripts/bench/n2_action_storm.mjs`: `N2_ACTION_ID` is no longer a required
external input. When unset, the harness now fetches
`<N2_BASE>/bench/action` and regexes the first `$ACTION_ID_<hex>` token from
the page HTML (`/\$ACTION_ID_([0-9a-f]+)/`). Explicit env still wins.
Scrape failure (fetch error, non-200, or no token in HTML) is a typed
`N2_ACTION_ID_FATAL` error thrown before any POST is sent — fail-closed,
never a silent empty id (the exact BK-BLD root cause). Doc comment in the
harness Env block updated to match.

## Witness (real output)

Fresh `next start -p 39872` on the current prod build (BUILD_ID
`3_pHdj3l7hYLMBVFcJWgz`), page 200 after 3 polls, page HTML renders
`$ACTION_ID_404cd2b45e8bdf190d573afb0b7bcce384c2bf9c23`.

Run 1 — `N2_ACTION_ID` unset (scrape path):

```
$ N2_BASE=http://127.0.0.1:39872 N2_VUS=2 N2_ITERS=2 node scripts/bench/n2_action_storm.mjs
F1 session_leak: PASS (leaks=0, transport_err=0, unexpected_status=0)
F2 invalid_rejection_100pct: PASS (1/1)
F3 p99<=350ms: PASS (p99=15.64ms)
exit=0
```

accepted=3, rejected=1/1 (rejection_rate=1.0), unexpected_status=0,
session_leaks=0, unique_rids=3, ops/s=173.9.

Run 2 — deliberately-wrong `N2_ACTION_ID=deadbeef…` (harness behavior
documented, not changed): env wins, empty-id-style 400s return, harness
counts them as `unexpected_status=4`, typed FAIL, exit 1:

```
$ N2_BASE=http://127.0.0.1:39872 N2_ACTION_ID=deadbeef… N2_VUS=2 N2_ITERS=2 node scripts/bench/n2_action_storm.mjs
F1 session_leak: FAIL (leaks=0, transport_err=0, unexpected_status=4)
F2 invalid_rejection_100pct: FAIL (0/0)
F3 p99<=350ms: PASS (p99=0ms)
exit=1
```

## Takedown

`next start` pid killed, port 39872 verified free (lsof). `workspace/.next/`
gitignored, nothing staged from it.

## Standing

ALIVE — scrape path witnessed exit 0 on a fresh prod server without any env;
wrong-env behavior documented as the harness's own typed FAIL (correct: an
explicit wrong id is an operator error, not a harness gap).
