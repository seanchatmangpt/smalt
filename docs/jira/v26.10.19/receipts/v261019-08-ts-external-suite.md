# Receipt — V261019-08 (ts-external-suite)

Context: solo(V261019-08) — census commands executed in this lane, 2026-10-19 ~10:10 PDT.
Standing: **PARTIAL / IN-FLIGHT** — the suite surface exists on disk
(`verification/ts/`: wf1..wf5 + harness) but the suite has NOT landed: no
lane receipt exists for a full green run, and the portable-target gate
currently exits 1 against the tree (output below, honest failure).
Base: 64f6099663a4ec32fd9478c4c39fca49ab1961f8 (shared checkout, 143 dirty paths)
Date: 2026-10-19

## What changed

- The external TypeScript suite moved from the old plan's `workspace/test/`
  to `verification/ts/` per the clean-room reset. On disk right now:
  `wf1/`–`wf5/`, `harness/`, `package.json`, `package-lock.json`,
  `node_modules/` (installed), `verification/README.md` documents the
  contract (boot via `mix run --no-start --no-halt`, no `lib/smalt` refs).
- Runner: `node --test` surface (`node:test` / `node:assert` are the only
  allowed test surface per `scripts/portable_target_gate.py`).
- No suite-owned fixes landed in this lane's file set; no `lib/` or
  `workspace/` edit disclosed by this receipt.

## Verification (real output tails)

```
$ find verification/ts -name "*.test.*" -not -path "*/node_modules/*" | wc -l
0
```

```
$ python3 scripts/portable_target_gate.py; echo "exit=$?"
[first lines]
/Users/sac/smalt/verification/ts/node_modules/which-typed-array/index.js:6: disallowed import: call-bound
...
[112 violation lines total; includes HARD violations in
 verification/ts/node_modules/wsl-utils/* and doc-text false positives in
 verification/README.md / verification/py/.venv]
exit=1
```

The portable gate's exit 1 is honest RED: the scanner currently descends
into `verification/ts/node_modules/` and `.venv` (third-party transitive
deps, not lane-authored code) and flags README prose. The suite owner must
either add scanner exclusions for installed third-party trees or pin
deps to clean versions before the suite can close green.

```
$ node --test verification/ts/     # NOT EXECUTED
```

Not run: the suite owner's WO-08, not this receipt lane; a full run without
scanner exclusions would be measuring the gate RED, not the suite.

## Acceptance greps

- `grep -rn "node:test" verification/ts --include="*.ts" -l | wc -l` — not
  migrated: zero `.test.ts` leaves exist yet (census above).
- `grep -n "test" verification/ts/package.json` — not censused by this lane
  (deferred to the suite owner).

## Deviations

1. Skeleton assumed `workspace/test/*.test.ts` leaves; the reset moved the
   external suite to `verification/ts/` with wf1..wf5 + harness layout.
   Recorded here as a measured deviation, not argued.
2. Standing is PARTIAL/IN-FLIGHT, not LANDED: no executed `node --test`
   run exists on the tree this session; the portable gate is RED (exit 1).

## Execution (Phase-3 TS baseline, this lane, 2026-10-19)

```
$ git rev-parse HEAD
a45cf03bdb6d72ffcd970c8783f0163c96fe5950
$ cd verification/ts && node run-all.mjs   # ONCE, self-booted substrate block=v13 ports 39830-39835
[run-all] done in 58.0s exit=1
```

Exit contract: run-all exit=1 = honest verdict (FAILs present). No SKIP
verdicts, no framework retries/timeouts observed. 37 checks across wf1-wf5:
30 GREEN, 1 REGISTERED-DIVERGENCE, 6 FAIL.

### Check:verdict:KD mapping table

| check | verdict | KD row(s) |
|---|---|---|
| rg-create, dead-port, policy-def/assignment, vnet-put, storage-lro, policy-deny, rg-tag-merge, rg-tags-null, missing-rg-404, rg-delete-lro, rg-gone-404 (wf1, 12) | GREEN | — |
| cosmos-8way-etag-race, dead-port, appconfig-ifmatch-race, appconfig-unconditional-409, appconfig-missing-404 (wf2, 5) | GREEN | — |
| **blob-auth-channel** (wf2) | **FAIL** | **KD-114** (blob data-plane auth channel) — 1:1 |
| **sb-send20-receive-complete** (wf3) | **FAIL** | **KD-115** (SB receiver zero-delivery) — 1:1 |
| **sb-message-lock-lost** (wf3) | **FAIL** | **KD-115** (starved by receiver gap, per row text) |
| **sb-dlq-maxdelivery** (wf3) | **FAIL** | **KD-115** (starved leg) |
| sb-session-fifo (wf3) | GREEN (detail notes divergence) | KD-116 (session delivery shape — registered, noted in check detail) |
| kv-challenge-witness-KD-15, kv-create, kv-two-versions, kv-wrap-unwrap, dead-port (wf4, 5) | GREEN | KD-15 challenge witnessed GREEN |
| **kv-sign-external-verify** (wf4) | **REGISTERED-DIVERGENCE#KD-14,KD-105** | **KD-14 + KD-105 + KD-119** (rs256/sign-shape family) — 1:1 |
| **kv-get-deleted** (wf4) | **FAIL** | **KD-117** (KV deleted-keys plane) — 1:1 |
| **kv-recover** (KD-117) | **FAIL** | **KD-117** — 1:1 |
| kv-purge (wf4) | GREEN | KD-117 plane (expected-404 leg passed as designed) |
| arm-429-burst, arm-429-typed-code, arm-429-sdk-observability, dead-port (wf5, 4) | GREEN | — |

### Findings

- **Zero UNMAPPED failures.** All 6 FAIL + 1 REGISTERED-DIVERGENCE verdicts
  map 1:1 to registered rows KD-114/115/117/14/105 (KD-119 family via the
  sign-shape class). No new KD candidate this run.
- **KD-118 (scheduleMessage-501) has NO covering check in this run** — the
  wf3 battery did not exercise scheduleMessage. Coverage note, not a
  failure; the row stays OPEN with its prior witness receipt.
- **KD-117 regression signal**: the register says "fix LANDED post-witness
  (egress_router.ex:1017-1039), witness pending" — this run at HEAD
  a45cf03 still FAILs kv-get-deleted/kv-recover with the same 404s, so the
  landed fix is not confirmed by this witness; row stays OPEN
  (fix-landed-partial stands, witness still pending).
- KD-15 challenge witness (kv-challenge-witness-KD-15) GREEN — handshake
  premise intact.
- Zero silent skips; every check produced an explicit verdict.

### Raw tail (verbatim)

```
-- wf3: child exit=0
   [FAIL] sb-send20-receive-complete — received=0/20 fifo=true — receiver-delivery gap: attach+flow+CBS succeed and send resolves, but no delivery is produced on receiver-link flow credit (send-side only on the wire)
   [GREEN] dead-port-plane-check — dead AMQP typed failure (MessagingError: ECONNREFUSED: connect ECONNREFUSED 127.0.0.1:1)
   [FAIL] sb-message-lock-lost — no delivery — receiver-delivery gap leaves the lock-expiry leg unexercisable over the SDK
   [FAIL] sb-dlq-maxdelivery — DLQ size=0 reason=null
   [GREEN] sb-session-fifo — received=[0,1,2,3,4] (deliveries lack settle methods — delivery-shape divergence)
   [GREEN] eh-hub-up — hub properties via $management link
   [GREEN] eh-send-200 — 100 events to partition 0, 100 to partition 1
   [GREEN] eh-exactly-once — unique=200/200 duplicates=0
-- wf4: child exit=0
   [GREEN] kv-challenge-witness-KD-15 — tokenless -> 401, WWW-Authenticate=Bearer authorization="https://localhost:39832/organizations", resource="https://localhost:39834", error="invalid_token",
   [GREEN] kv-create-rsa2048 — kid=https://localhost:8443/keys/wf4-56a34e40/7
   [GREEN] kv-two-versions — versions=2
   [GREEN] kv-wrap-unwrap — wrap/unwrap roundtrip equal=true
   [REGISTERED-DIVERGENCE#KD-14,KD-105] kv-sign-external-verify — external node:crypto verify=false (child status=0) — signature-shape divergence per KD-14/KD-105
   [GREEN] dead-port-plane-check — dead TLS twin typed failure (RestError)
   [GREEN] kv-soft-delete — DELETE /keys -> 200 (deletedDate present)
   [FAIL] kv-get-deleted — GET /deletedkeys -> 404 (recoverable-plane MISSING — recover/purge unexercisable)
   [FAIL] kv-recover — POST /deletedkeys/recover -> 404
   [GREEN] kv-purge — DELETE /deletedkeys (purge) -> 404; post-purge /keys/wf4-56a34e40 -> 404
-- wf5: child exit=0
   [GREEN] arm-429-burst — 180/200 requests 429'd, retry-after=1
   [GREEN] arm-429-typed-code — error.code=TooManyRequests status429x180
   [GREEN] arm-429-sdk-observability — SDK maxRetries:0 single GET: threw429=false resolved=false (window-dependent; burst leg is the throttle witness)
   [GREEN] dead-port-plane-check — dead port typed failure (TypeError)
[run-all] done in 58.0s exit=1
```

Standing: **PARTIAL_ALIVE** — suite executes end to end (37/37 verdicts,
honest exit=1); 30 GREEN / 7 divergence-or-fail, all registered.
