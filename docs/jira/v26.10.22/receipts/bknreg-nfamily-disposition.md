# BK-NREG — n-family (n1-n8) typed disposition register

**Standing:** **PARTIAL_ALIVE**
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main)
Lane: BK-NREG
Parent: BK-NENV (`bknenv-debug-faces.md`), REGISTRY.md v-law retire markings (64f6099)

## Method

Existence checks, not full runs: (1) all eight harnesses read
(`scripts/bench/n1..n8*.mjs`); (2) every measured subject surface checked on
HEAD — all exist:

| lane | subject surface | alive on HEAD? |
|---|---|---|
| n1 | `workspace/app/bench/grid/page.tsx` | YES |
| n2 | `workspace/app/bench/action/page.tsx` (+ server action) | YES |
| n3 | RSC streaming faces (`/bench`) | YES |
| n4 | `workspace/app/api/v1/ingest/route.ts` | YES |
| n5 | `workspace/app/bench/compute/page.tsx` | YES |
| n6 | `app/bench/news/[slug]/page.tsx` + `app/api/bench/isr-stats/route.ts` | YES |
| n7 | `app/api/v1/stream/route.ts` (SSE, SMALT_DEBUG_FACES-gated) | YES |
| n8 | `app/console/page.tsx`, `app/bench/audit/page.tsx` | YES |

Retirement is of the **lane registration**, not the surface. Workspace prod
build is stale vs `app/` sources (`.next/BUILD_ID` older than the route
files), so any in-spec `next start` leg requires a rebuild.

## Per-lane disposition

| lane | disposition | reason |
|---|---|---|
| n1 | PERMANENT-RETIRED | Playwright+CDP; not cheaply runnable in registrar scope |
| n2 | PERMANENT-RETIRED | spec is `next start` prod; dev probe leg FAIL (below) |
| n3 | PERMANENT-RETIRED | Playwright+CDP; not cheaply runnable |
| n4 | **ACTIVE-WITH-WITNESS** | real leg on HEAD, exit 0 (below) |
| n5 | PERMANENT-RETIRED | own `next start` vs stale build; needs rebuild |
| n6 | PERMANENT-RETIRED | external prod ISR; needs rebuild; preflight armed (BK-NENV) |
| n7 | **ACTIVE-WITH-WITNESS** | real leg, verdict 0 divergence (below) |
| n8 | PERMANENT-RETIRED | 500-cycle Playwright soak; not cheaply runnable |

## Witness legs (real output, gate-ON `next dev -p 39826`, v-law ad hoc band 39826..39839; dev server serves HEAD sources — the stale prod build was NOT used)

### n4 — exit 0

```
$ TARGET=http://127.0.0.1:39826 WINDOWS=1 SECS=3 RPS=50 OUT=tmp/nreg-n4-witness.jsonl node scripts/bench/n4_ingest_saturation.mjs
[warmup] valid-sig status=202 socketErr=- ; bad-sig status=401
[window 1/1] running 3s @ 50 rps target...
[window 1] achieved=13.7 rps, p50=4.453ms p95=5.768ms p99=7.468ms, 202=121 429=0 401=30, socketErr={}
[done] wrote 1 rows to tmp/nreg-n4-witness.jsonl
exit 0
```

### n7 — verdict 0 divergence

```
$ node scripts/bench/n7_sse_herd.mjs --url http://127.0.0.1:39826/api/v1/stream --target 1 --jsonl tmp/nreg-n7-witness.jsonl
[n7] ulimit -n = 1048576, target = 1
[n7] ramp active=1 attachErrors=0 runAt=1
[n7] storm fired: {"aborted":1}
[n7] post-storm active=1
[n7] reconnect settled active=1
[n7] verdict divergence=0.0000% permanent=0 attachErr=0 overflows=0 handles=[5..5]
```

jsonl verdict row: `{"phase":"verdict","herd_size":1,"permanent_drops":0,
"divergence_rate":0,"server_seq":299,"elapsed_ms":15619}`.

### n2 — typed FAIL (probe evidence, not a witness pass)

```
$ N2_BASE=http://127.0.0.1:39826 N2_VUS=2 N2_ITERS=2 node scripts/bench/n2_action_storm.mjs
unexpected_status=4, accepted=0, F1 session_leak: FAIL, F2: FAIL (0/0), n2 exit=1
```

All 4 POSTs returned an unexpected status in dev mode; the lane's spec
(`next start` prod, `$ACTION_ID` flight routing) was not exercised. Recorded
as probe evidence only — n2 stays PERMANENT-RETIRED.

## Defects found (unfixed, out of lane scope)

1. **n7 does not exit after the verdict** — open SSE response sockets hold
   the node event loop; the process hangs at exit until killed. Any revival
   must wrap n7 with a timeout (as this lane did) until a `process.exit` /
   socket-teardown fix lands. Noted in the REGISTRY n7 row.
2. Workspace prod build stale vs `app/` (affects n2/n5/n6 revival).

## Commit disclosure (fix-forward, same-checkout fan-out law 6)

Commit baa2b516 was made without pathscoping and swept in one already-staged
foreign 1-line edit owned by lane BK-PRDR
(`docs/jira/v26.10.22/receipts/bkprdr-prd-matrix.md`, expl5r1 court-filename
correction). BK-PRDR's content is landed intact and attributed here; no
content was lost or altered.

## Standing

PARTIAL_ALIVE — n4/n7 witnessed ACTIVE on HEAD sources (real legs, embedded);
n1/n2/n3/n5/n6/n8 typed PERMANENT-RETIRED with reasons. No silent rows:
REGISTRY.md carries all eight typed dispositions. Re-activation of any
n-lane still requires port-block registration + successor receipt per the
REGISTRY a/n rule.
