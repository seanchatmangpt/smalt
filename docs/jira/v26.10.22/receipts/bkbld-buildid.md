# BK-BLD — workspace prod build rebuild + n2 re-witness

**Standing:** **PARTIAL_ALIVE**
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main)
Lane: BK-BLD
Parent: BK-NREG (`bknreg-nfamily-disposition.md`), REGISTRY.md v-law markings (64f6099)

## Trigger

BK-NREG typed workspace `.next/BUILD_ID` stale vs `app/` sources; n2's
typed-FAIL evidence was `unexpected_status=4` on a dev probe. Task: rebuild,
re-witness n2 against the fresh prod build, record the real verdict.

## Build leg (real output)

```
$ cd workspace && npm run build
   ▲ Next.js 16.4.2
... (route table: /bench/action, /api/v1/ingest, /api/v1/stream,
    /bench/news/[slug] SSG 51 paths, /console, /process, ...) 
exit=0
```

- old BUILD_ID: `hW6Kk2OnIggUhos2l-8UP`
- new BUILD_ID: `3_pHdj3l7hYLMBVFcJWgz`

## n2 re-witness leg (real output)

`next start -p 39851` on the fresh build (ready, GET /bench/action → 200).
First probe run reproduced the typed FAIL exactly — root cause identified:

```
$ N2_BASE=http://127.0.0.1:39851 N2_VUS=2 N2_ITERS=2 node scripts/bench/n2_action_storm.mjs
unexpected_status=4 ... F1: FAIL F2: FAIL (0/0) ... exit=1
# curl reproduction: 400 Bad Request, header `x-nextjs-action-not-found: 1`
# harness sends field `$ACTION_ID_` (N2_ACTION_ID unset → empty id)
# real id rendered in built page HTML:
$ACTION_ID_404cd2b45e8bdf190d573afb0b7bcce384c2bf9c23
```

The FAIL was a **probe artifact, not build staleness**: the harness POSTs the
progressive-enhancement field `$ACTION_ID_<id>` with an empty id, which Next
refuses with `x-nextjs-action-not-found` 400 before the action runs.

Re-run with the real action id:

```
$ N2_BASE=http://127.0.0.1:39851 N2_ACTION_ID=404cd2b45e8bdf190d573afb0b7bcce384c2bf9c23 \
  N2_VUS=2 N2_ITERS=2 node scripts/bench/n2_action_storm.mjs
F1 session_leak: PASS (leaks=0, transport_err=0, unexpected_status=0)
F2 invalid_rejection_100pct: PASS (1/1)
F3 p99<=350ms: PASS (p99=7.1ms)
n2 exit=0
```

Summary: accepted=3, rejected=1/1 (rejection_rate=1.0), unexpected_status=0,
session_leaks=0, unique_rids=3, p99=7.1ms, ops/s=363.6.

## Verdict

n2's surface is healthy on the fresh prod build. The prior typed-FAIL was a
harness invocation gap (missing `N2_ACTION_ID`), not staleness and not a
surface defect. REGISTRY n2 row updated PERMANENT-RETIRED →
**ACTIVE-WITH-WITNESS** (revival runs must set `N2_ACTION_ID` from the built
page; re-activation still requires port-block registration per the a/n rule).

## Build-output hygiene

`workspace/.next/` is gitignored (`workspace/.gitignore:2` → `.next/`);
verified nothing under `.next/` is staged or tracked. Not committed.

## Standing

PARTIAL_ALIVE — build fresh (new BUILD_ID, exit 0); n2 witnessed passing on
the prod build with the correct `$ACTION_ID`; REGISTRY row flipped. n5/n6
revival still blocked on their own `next start` legs (build staleness excuse
is now removed for both — their dispositions cite the stale build, which this
lane closed).
