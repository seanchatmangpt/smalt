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

---

# court-x2 #2 (post-AZB-25c promotion re-run) — 2026-10-20

Standing: ALIVE
Context: solo(just court ×2)

Both runs executed at the AZB-25c-fixed tree (`deb0795` — exemption_applies?
downcase), before the examples-wave docs commits. HEAD during BOTH run windows
(correlated via log mtimes 03:32:08 / 03:42:33 UTC vs git log): `deb0795` —
the pair's shas are identical by construction of the run windows.

- Run A: `just court` → log `/tmp/courtA.out`, exit=0 (`COURT-A rc=0`)
- Run B: `just court` → log `/tmp/courtB.out`, exit=0 (`COURT-B rc=0`)
  (run B is the log fed to `mint_release_receipt.py` for the re-minted
  `release-receipt.json`, `subject.sha = 2fcc4139fdfa853d52a9e26d78f47c2a740a08d8`)

## Run A tail (/tmp/courtA.out, last 12 lines)

```
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
COURT-A rc=0
```

## Run B tail (/tmp/courtB.out, last 12 lines)

```
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
COURT-B rc=0
```

## Falsifier

Either tail line reading anything but `rc=0`, or the run windows straddling a
commit (they do not — both predate 05:40:51 UTC examples-wave commits),
invalidates this section. Neither observed.


## court-x2 #3 (capability wave-1 promotion re-run, 2026-10-20)

Both runs of the full 11-stage court at the capability wave-1 HEAD
(17fcbb6d52d02917f9a1ff02a4b3c8572911ebda): two consecutive greens, no
shifted failures, run after the AZB-25c policy fix and the full capability
wave-1 integration (KV deleted-keys, secrets backup/restore, certificates,
PS256, scheduleMessages, EG webhook receiver, LRO widen, tags-at-scope,
RBAC scopes + locks, EH consumer groups, cosmos cascade, Atlas/KQL/MCP
raises, throttle profiles, blob snapshot/lease raises).

```
COURT-X1 rc=0 — [COURT] Full gate passed.
COURT-X2 rc=0 — [COURT] Full gate passed.
```

Run 2 is the court-log input to the re-minted release receipt. Falsifier:
re-run `MIX_BUILD_ROOT=_build-coord just court` twice at this HEAD.

## court-x2 #4 (capability wave-2 promotion re-run, 2026-10-20)

Both runs of the full 11-stage court at the capability wave-2 HEAD
(61e054389b1e5985a546d05938d55b24cf623fe4): two consecutive greens, no shifted failures. Wave-2 surface
under court: KV deleted-keys TLS twin, enforcementMode, cosmos
env-first+heir, PS256 dispatch, ACL body-seam + lease-on-snapshot,
SB topics ARM, EH ARM consumer groups, cosmos SQL OFFSET/TOP, policy
remediations, KV rotate, appconfig snapshots module, sentinel
multi-table, MCP 20-tool surface, wf6/wf7 diagnostics.

```
COURT-Y1 rc=0 — [COURT] Full gate passed.
COURT-Y2 rc=0 — [COURT] Full gate passed.
```

Run 2 is the court-log input to the re-minted release receipt.
