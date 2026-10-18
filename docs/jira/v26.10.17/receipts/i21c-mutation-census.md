# i21c — mutation-court + census court-stage pre-run #3

Date: 2026-10-17 · Lane: bench-runner (solo) · Repo: /Users/sac/smalt
Standing: **PASS** (mutation-court NON-VACUOUS, exit 0) + **SKIP (loud, exit 0)** (census)

Context: solo

## mutation-court (`just mutation-court` → scripts/mutation_court.py)

Real output (exit **0**):

```
==============================================================================
MUTATION COURT RECEIPT  (subject: /Users/sac/smalt @ lib/smalt/graphlaw/validator.ex)
served port: 9443
==============================================================================
MUTATION               PHASE   HTTP   EXPECTED                 VERDICT
M1 valid VM PUT        BEFORE  202    200/201/202              PASS
M2 missing vmSize      BEFORE  400    400 InvalidResourceShape PASS
M3 missing location    BEFORE  400    400 InvalidResourceShape PASS
M4 unadmitted type     BEFORE  400    400 InvalidResourceShape PASS
M2 missing vmSize      AFTER   202    200/201/202 (admitted)   PASS
M3 missing location    AFTER   201    200/201/202 (admitted)   PASS

validator.ex restored byte-exact (sha256): True
==============================================================================
VERDICT: NON-VACUOUS — gate present refuses, gate absent admits, restore verified.
MUTATION_COURT_EXIT=0
```

Notes (honest reporting): the first ~11 boot attempts failed
(`[court] boot failed (substrate exited rc=1; log=...mutation_court_boot_*.log); retry in 5s`)
before the harness's retry loop landed a substrate on 9443. The court then
completed all BEFORE/AFTER probes, the post-restore M2 re-check (CONFIRM 400),
and the byte-exact sha256 restore verification. No source edits were made.

## census (`just census`)

`SMALT_SDK_ROOT` was unset in the lane environment, so the loud-skip branch
fired (exit **0**, recorded verbatim):

```
SMALT_SDK_ROOT=<unset>
[COURT] census SKIP: SMALT_SDK_ROOT not set
CENSUS_EXIT=0
```

Branch: first guard (`-z "${SMALT_SDK_ROOT:-}"` → SKIP + exit 0). The real-SDK
replay (`scripts/sb_census_replay.sh`) was not reached. The census tail of
`just court` would degrade identically.

## Verdict for attempt 4

Both stages are exit 0: mutation-court NON-VACUOUS with verified restore;
census loud-SKIP on missing env (never a fake pass). Cleared for attempt 4.
