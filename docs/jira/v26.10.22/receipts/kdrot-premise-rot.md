# KD-ROT: register/doc premise-rot repairs (KD-135, KD-141, smalt-cli KD-49 banner)

**Standing:** ALIVE — all three repairs landed and grep-verified on disk; no status flips
(the register cell statuses are byte-unchanged).
**Context**: solo

## Subject

- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` rows KD-135 / KD-141 (text + premise
  anchor correction only; CLOSED-WITH-RECEIPT / CLOSED-SIMULATED statuses untouched).
- `smalt-cli/tests/test_servicebus.py`, `smalt-cli/tests/test_eventhub.py`
  (`KD49_SKIP` banner text; skip-firing signature matching unchanged — runtime
  behavior identical).

Basis receipts: `docs/jira/v26.10.22/receipts/kdblob-error-contract.md` (findings 2-3,
court 12/12 ALIVE) + `test/internal/kd_blob_court_test.exs` legs KD-135/KD-141.

## Repairs

1. **KD-135** — premise cell re-anchored to HEAD: containers now create with
   `immutable` defaulting FALSE (`lib/smalt/data_plane/blob_storage.ex:178-180`,
   `# KD-COVERS: KD-135` at :177), immutability opted IN via `x-ms-immutable-policy`
   (`lib/smalt/egress_router.ex:1368-1377`); delete arm
   `immutable==true and not policy_present?` at `blob_storage.ex:2234`. Pinion cell
   amended in place: the live wire answers **202 Accepted** on blob DELETE vs a
   default container (court KD-135 leg; WORM `ContainerLocked` reserved for
   policy-bearing containers) — more Azure-aligned than the pinion's
   "409 forever" text, which is retained as history, marked stale.
2. **KD-141** — closed cell gains the witnessed note: the guard lives at the Bandit
   transport layer (bare HTTP/1.0 400 before the router; the census-era smalt-500
   shape is structurally unreachable on current HEAD); pinned refused typed 400,
   never 500, at whichever layer.
3. **BK-11 F2** — `SKIP-KD49` banner in both AMQP test files updated: both KD-49 and
   KD-77 are CLOSED-SIMULATED (KD-49: `receipts/s1-amqp-shims.md`; KD-77:
   `docs/jira/v26.10.16/receipts/lane9-reference-rewrite.md`); the skip is retained
   as a loud regression tripwire only. Note: `SKIP-KD18` does not exist anywhere in
   `smalt-cli/` (grep: zero hits) — only `SKIP-KD49` was stale.

## Verification (embedded output)

```
$ grep -rn 'SKIP-KD49\|SKIP-KD18' smalt-cli/ | grep -v node_modules
smalt-cli/tests/test_servicebus.py:45:    "SKIP-KD49(KD-49 CLOSED-SIMULATED, KD-77 CLOSED-SIMULATED): both rows "
smalt-cli/tests/test_eventhub.py:69:    "SKIP-KD49(KD-49 CLOSED-SIMULATED, KD-77 CLOSED-SIMULATED): both rows "

$ python3 -m py_compile smalt-cli/tests/test_servicebus.py smalt-cli/tests/test_eventhub.py && echo PY-OK
PY-OK

$ grep -c 'PREMISE CORRECTED 2026-10-22 lane KD-ROT' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
1
$ grep -c 'WITNESS NOTE (KD-ROT 2026-10-22' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
1
$ grep -c 'WITNESS CORRECTION (KD-ROT 2026-10-22' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
1
```

Diff shape: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` +2/-2 lines (rows KD-135 at
:316, KD-141 at :322 only; the KD-140 row sharing the fix1 witness string is
untouched — line-targeted edit), each test file +10/-6.

## Standing

ALIVE. No code behavior changed; no KD row status flipped; `scripts/kd_flip.py` not
invoked (text/anchor correction, not a flip — flip gate not owed). Receipts basis
(kdblob court 12/12) predate this edit; anchors re-read at use time from HEAD.
