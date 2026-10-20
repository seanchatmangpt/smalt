# v26.10.19 court-x2 close — two greens at one SHA

Standing: ALIVE
Context: solo(just court ×2)
Date: 2026-10-19

Run command (both runs, run 2 launched only after run 1 rc=0):

    nohup bash -c 'just court >/tmp/court3.out 2>&1; echo "COURT-RUN2B rc=$?" >> /tmp/court3.out' </dev/null >/dev/null 2>&1 &

- Run 1: `just court` → log `/tmp/court2.out`, exit=0 (COURT-RUN2 rc=0)
- Run 2: `just court` → log `/tmp/court3.out`, exit=0 (COURT-RUN2B rc=0)

## SHA identity

- `git rev-parse HEAD` before run 1, between runs, and after run 2:
  `81a7a29cd3b15ab6fede2f000d4220aa1eadf235` (unchanged; reflog shows last
  commit 19:08:49 -0700, before both run windows).

## Run 1 verdict tail (/tmp/court2.out, last 16 lines)

```
=== [INVARIANT-GATE] queue-capacity ===

================ INVARIANT-GATES VERDICT TABLE ================
  appconfig-etag-cas   PASS
  blob-worm            PASS
  cosmos-etag-cas      PASS
  ledger-chain         PASS
  lock-clamp           PASS
  queue-capacity       PASS
================================================================
[INVARIANT-GATES] PASS: 6/6 gates (positive held + all negative fixtures refused).
[NAMING-SWEEP] PASS: 0 violations / 49 allowed
[PASS] non-duplication gate: 6 file(s) clean
[PASS] portable-target gate: 22 file(s) clean
[COURT] Full gate passed.
COURT-RUN2 rc=0
```

## Run 2 verdict tail (/tmp/court3.out, last 16 lines)

```
=== [INVARIANT-GATE] queue-capacity ===

================ INVARIANT-GATES VERDICT TABLE ================
  appconfig-etag-cas   PASS
  blob-worm            PASS
  cosmos-etag-cas      PASS
  ledger-chain         PASS
  lock-clamp           PASS
  queue-capacity       PASS
================================================================
[INVARIANT-GATES] PASS: 6/6 gates (positive held + all negative fixtures refused).
[NAMING-SWEEP] PASS: 0 violations / 49 allowed
[PASS] non-duplication gate: 6 file(s) clean
[PASS] portable-target gate: 22 file(s) clean
[COURT] Full gate passed.
COURT-RUN2B rc=0
```

## Falsifier

Either log line `COURT-RUN2 rc` / `COURT-RUN2B rc` reading anything but 0, or
`git rev-parse HEAD` differing across the two run windows, invalidates this
receipt. Neither observed.
