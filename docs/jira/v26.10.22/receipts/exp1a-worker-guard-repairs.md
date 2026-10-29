# EXP1-A — law-reticle worker / guard / bridge repairs (W1, W6)

**Standing:** **ALIVE** — all repairs landed, court PASS 17/17 legs, `just ws-lint` 0 errors.
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main)
Closes: EXPLORE1-W1, EXPLORE1-W6 (docs/jira/v26.10.22/receipts/expl1-workspace-errc.md)

## Files (lane-owned, all edits)

- `workspace/workers/law-reticle.worker.ts`
- `workspace/lib/engine/guard.ts`
- `workspace/lib/engine/law-worker-bridge.ts`
- `workspace/scripts/guard-court.mjs` (court extension)

## W1 — SHACL admission gate fail-closed

`evaluateSieve` (the exact function the worker's ADMIT_INPUT path runs) now
refuses typed unless op-1 returns an explicitly-present, boolean-typed
`conforms`:

- `conforms` absent → status 1 `SHACL_VERDICT_ABSENT` (ABI-drift witness)
- non-boolean `conforms` → status 1 `SIEVE_RESPONSE_MALFORMED: non-boolean ...`
- missing `results` array → status 1 `SIEVE_RESPONSE_MALFORMED`
- `conforms === false` → status 1 `non-conformant: <component> at <focus>`
- `conforms === true` + results array → status 0 admit

Op-2 (N3) semantics unchanged; `ok !== true` handling unchanged (per exclusions).

## W6 — Guard/worker lifecycle

- **(a) guard.ts dispose** (pre-existing half, verified): in-flight admissions
  resolve typed `GUARD_FAULT` ("guard disposed with in-flight admission"),
  never hang.
- **(b) law-worker-bridge.ts init**: a REJECTED ready promise is no longer
  memoized — the `.catch` clears `readyPromise` before rethrowing, so the
  next `init()` retries instead of failing INIT for the page lifetime.
- **(c) worker onmessage**: the handler body is wrapped in try/catch posting a
  typed status-2 `WORKER_FAULT` verdict — a malformed packet-4 frame can no
  longer swallow the response.
- **(d) Guard.call bounded timeout**: every call carries a timeout
  (default 10s, constructor-tunable for courts); a silent worker resolves
  typed `GUARD_TIMEOUT` within the bound, pending entry dropped so a late
  response cannot settle a stale awaiter; timers cleared on settle and dispose.

## Court — `workspace/scripts/guard-court.mjs` (17 legs, all PASS)

Compiles worker+guard+bridge with the workspace tsc, drives the real
`evaluateSieve`, the real `Guard` promise machinery, and the real
`LawWorkerBridge` retry path; only the wasm edge is a hand-written fake
(not instantiable in plain node).

Embedded output (real run, 2026-10-22):

```
$ node scripts/guard-court.mjs
[PASS] a  well-formed conforms:true admits — {"status":0}
[PASS] b  conforms:false ANDONs (non-conformant) — reason=non-conformant: minCount at urn:s
[PASS] c  response missing conforms -> SHACL_VERDICT_ABSENT ANDON, no admit — reason=SHACL_VERDICT_ABSENT: conforms field absent from shacl verdict
[PASS] c  no status-0 verdict minted for the absent-verdict shape
[PASS] d  string "true" conforms -> SIEVE_RESPONSE_MALFORMED ANDON — reason=SIEVE_RESPONSE_MALFORMED: non-boolean conforms (string)
[PASS] e  op-2 n3 ok:true still admits — {"status":0}
[PASS] e2 transport refusal still ANDONs typed — reason=gl_alloc refused 42 bytes
[PASS] f  missing results array -> SIEVE_RESPONSE_MALFORMED ANDON
[PASS] g  andonRule maps SHACL_VERDICT_ABSENT to the selector
[PASS] h  dispose resolves in-flight admission typed GUARD_FAULT
[PASS] h2 dispose also drains the hung INIT call
[PASS] i  malformed ADMIT_INPUT still posts exactly one typed response — {"id":41,"verdict":{"status":2,"detail":"wasm not initialized","ms":0}}
[PASS] i2 posted verdict carries a detail string, not an exception object
[PASS] j  first init with a failing spawn rejects typed — worker spawn failed (simulated bad URL)
[PASS] j2 retry init after a rejected memo succeeds end to end — {"status":"ADMITTED","ms":1}
[PASS] k  silent worker -> typed GUARD_TIMEOUT within the bound — {"status":2,"detail":"GUARD_TIMEOUT: no response within 60ms","ms":60} in 62ms

# guard court verdict: PASS (0 failure(s))
EXIT=0
```

Falsifier coverage: fake gl_call `{"ok":true}` (no conforms) refuses typed
(leg c); `{"ok":true,"conforms":true}` admits (leg a); `conforms:false`
refuses with component/focus detail (leg b); silent/terminated worker refuses
typed `GUARD_TIMEOUT` in 62ms against a 60ms bound, never a hang (leg k);
dispose mid-admit settles typed (legs h/h2).

## Lint

```
$ just ws-lint   # exit 0 — 0 errors, 49 warnings (all pre-existing: unused-var style in test/worker files)
```

## Non-vacuity note

Legs c/f assert the negative reason tokens minted only by the new fail-closed
branches; legs j/j2 assert the retry path exists only because the memo clear
lands (a bridge that still memoized the rejection fails j2 with "INIT failed"
forever); leg k asserts the bound is actually observed (62ms vs unbounded
hang).
